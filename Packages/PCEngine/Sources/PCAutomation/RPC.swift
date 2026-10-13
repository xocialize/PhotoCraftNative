// Port of photocraft-automation (crates/automation/src/rpc.rs: `METHODS`, `Headless::handle`, `batch_with_budget`, `respond`, `serve_lines`, `serve_tcp`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The headless JSON-lines server (`pccli serve`): the control protocol's envelope
// (`{"id","method","params"}` → `{"id","ok","result"|"error"}`) over one shared session, on stdio
// or an authenticated loopback TCP port. Methods (camelCase params):
// - `engine.execute {command, params?, wait?}` / `engine.commands {filter?}`
// - `jobs.list` / `jobs.cancel {job?}`: background jobs
// - `session.list`, `doc.open {path}`, `doc.new {…file.new params}`, `doc.place {path, scale?,
//   fit?, center?, index?}`, `doc.exportLayers {dir, format?, prefix?, visibleOnly?, quality?,
//   index?}`, `doc.exportDataSets {dir, format?, dataSets?, naming?, index?}`,
//   `doc.importDataSets {path, delimiter?, index?}`, `doc.save {path?, format?, quality?, index?,
//   tiffLayers?, tgaBits?}`, `doc.inspect {index?}`, `doc.render {index?, maxSide?, path?}`,
//   `doc.select {index}`, `doc.close {index?}`
// - `batch {steps: [{command, params?, wait?} | {method, params?}], stopOnError?}`
// - `methods`: this list.

import Darwin
import Foundation
import PCDocument
import PCEngine
import Synchronization

/// Method names served by `Headless.handle` (photocraft `METHODS`).
public enum RPC {
    public static let methods = [
        "engine.execute", "jobs.list", "jobs.cancel", "engine.commands", "session.list", "doc.open", "doc.place", "doc.new", "doc.save",
        "doc.exportLayers", "doc.exportDataSets", "doc.importDataSets", "doc.inspect", "doc.render", "doc.select", "doc.close", "batch",
        "methods",
    ]
}

extension Headless {
    /// The method table, kept where the first port exposed it.
    public static var methods: [String] { RPC.methods }

    /// photocraft `index_of`: a non-negative integer `index`, else none.
    static func indexOf(_ p: JSONValue) -> Int? { p["index"]?.uint64Value.map { Int(clamping: $0) } }

    /// `p` without `keys` (the method's own fields), as the command's options.
    static func options(_ p: JSONValue, removing keys: [String]) -> JSONValue {
        var o = p.members
        for k in keys { o[k] = nil }
        return .object(o)
    }

    /// Dispatches one request. Unknown methods and bad params are errors, never traps.
    public func handle(_ method: String, _ params: JSONValue) throws -> JSONValue {
        syncJobs()
        let p = params == .null ? JSONValue.object([:]) : params
        func str(_ k: String) -> String? { p[k]?.stringValue }
        switch method {
        case "engine.execute":
            guard let id = str("command") else { throw AutomationError.badRequest("engine.execute needs `command`") }
            return try commandStart(id, p["params"] ?? .null, wait: p["wait"]?.boolValue ?? true)
        // Background jobs (#210): list (applying any that finished) and cancel.
        case "jobs.list": return try commandStart("jobs.list", .object([:]), wait: true)
        case "jobs.cancel": return try commandStart("jobs.cancel", p, wait: true)
        case "engine.commands":
            let all = commandList()
            guard let needle = str("filter")?.lowercased() else { return all }
            return .array((all.arrayValue ?? []).filter { c in
                "\(c["id"]?.stringValue ?? "") \(c["label"]?.stringValue ?? "")".lowercased().contains(needle)
            })
        case "session.list": return sessionList()
        case "doc.open":
            guard let path = str("path") else { throw AutomationError.badRequest("doc.open needs `path`") }
            return try open(path)
        case "doc.place":
            guard let path = str("path") else { throw AutomationError.badRequest("doc.place needs `path`") }
            return try place(index: Self.indexOf(p), path: path, params: Self.options(p, removing: ["path", "index"]))
        case "doc.new": return try commandRun("file.new", p)
        case "doc.save":
            let tgaBits = try FlatFiles.tgaBitsParam(p, "doc.save")
            var opts = FlatFiles.ExportOptions(tiffLayers: p["tiffLayers"]?.boolValue ?? false, tgaBits: tgaBits)
            if let q = p["quality"]?.uint64Value { opts.quality = Int(min(max(q, 1), 100)) }
            return try save(index: Self.indexOf(p), path: str("path"), format: str("format"), options: opts)
        case "doc.exportLayers", "doc.exportDataSets":
            guard let dir = str("dir") else { throw AutomationError.badRequest("\(method) needs `dir`") }
            let opts = Self.options(p, removing: ["dir", "index"])
            return method == "doc.exportLayers"
                ? try exportLayers(index: Self.indexOf(p), dir: dir, params: opts)
                : try exportDataSets(index: Self.indexOf(p), dir: dir, params: opts)
        case "doc.importDataSets":
            guard let path = str("path") else { throw AutomationError.badRequest("doc.importDataSets needs `path`") }
            return try importDataSets(index: Self.indexOf(p), path: path, params: Self.options(p, removing: ["path", "index"]))
        case "doc.inspect": return try inspect(Self.indexOf(p))
        case "doc.render":
            let maxSide: Int
            if let v = p["maxSide"] {
                guard let n = v.uint64Value, n <= UInt64(UInt32.max) else {
                    throw AutomationError.badRequest("maxSide must be an unsigned 32-bit integer")
                }
                maxSide = Int(n)
            } else {
                maxSide = 1024
            }
            let png = try renderPNG(Self.indexOf(p), maxSide: maxSide)
            if let path = str("path") {
                try writeRender(path, png)
                return ["path": .string(path), "bytes": .int(png.count)]
            }
            return ["mime": "image/png", "base64": .string(png.base64EncodedString())]
        case "doc.select":
            guard let i = Self.indexOf(p) else { throw AutomationError.badRequest("doc.select needs `index`") }
            return try select(i)
        case "doc.close": return try close(Self.indexOf(p))
        case "batch": return try batch(p)
        case "methods": return .strings(RPC.methods)
        default: throw AutomationError.badRequest("unknown method `\(method)` (try `methods`)")
        }
    }

    /// Runs `steps` in order: `{command, params?, wait?}` (an engine command) or `{method,
    /// params?}` (any method but `batch`). Stops at the first error unless `stopOnError` is false;
    /// the reply lists every step's result.
    public func batch(_ p: JSONValue) throws -> JSONValue {
        try batch(p, budget: Budgets.BatchReplyBudget())
    }

    /// `batch` with a caller's reply budget (MCP charges escaped sizes). Steps stop once the
    /// budget runs out, even when `stopOnError` is false.
    public func batch(_ p: JSONValue, budget: Budgets.BatchReplyBudget) throws -> JSONValue {
        guard let steps = p["steps"]?.arrayValue else { throw AutomationError.badRequest("batch needs `steps`") }
        if steps.count > ControlSecurity.maxBatchSteps {
            throw AutomationError.badRequest("batch contains \(steps.count) steps; maximum is \(ControlSecurity.maxBatchSteps)")
        }
        let stop = p["stopOnError"]?.boolValue ?? true
        var budget = budget
        var results: [JSONValue] = []
        var failed = 0
        for (i, s) in steps.enumerated() {
            let params = s["params"] ?? .null
            let r: Result<JSONValue, EngineError>
            if let c = s["command"]?.stringValue {
                // Like `engine.execute`: `wait: false` starts a long command as a background job.
                r = Result { try commandStart(c, params, wait: s["wait"]?.boolValue ?? true) }.mapError(EngineError.wrap)
            } else if let m = s["method"]?.stringValue {
                r = m == "batch" ? .failure(AutomationError.badRequest("nested batch")) : Result { try handle(m, params) }.mapError(EngineError.wrap)
            } else {
                r = .failure(AutomationError.badRequest("step \(i) needs `command` or `method`"))
            }
            let item: JSONValue
            switch r {
            case .success(let v): item = ["ok": true, "result": v]
            case .failure(let e): item = ["ok": false, "error": .string(e.description)]
            }
            do { try budget.charge(item) } catch {
                failed += 1
                results.append(["ok": false, "error": .string("batch response budget exceeded; current step may have completed: \(EngineError.wrap(error))")])
                break
            }
            results.append(item)
            if case .failure = r {
                failed += 1
                if stop { break }
            }
        }
        return ["completed": .int(results.count - failed), "failed": .int(failed), "results": .array(results)]
    }

    /// One request line → one reply (`{"id","ok","result"|"error"}`); malformed JSON gets
    /// `id: null` (photocraft `respond`). The reply is not yet bounded: `Budgets.replyLine` is.
    public func respond(line: String) -> JSONValue {
        let req: JSONValue
        do { req = try JSONValue.parse(line) } catch { return ["id": .null, "ok": false, "error": .string("bad JSON: \(error)")] }
        let id = req["id"] ?? .null
        guard let method = req["method"]?.stringValue else { return ["id": id, "ok": false, "error": "missing `method`"] }
        do {
            return ["id": id, "ok": true, "result": try handle(method, req["params"] ?? .null)]
        } catch {
            return ["id": id, "ok": false, "error": .string(EngineError.wrap(error).description)]
        }
    }
}

/// A headless session shared by several connections (photocraft's `Arc<Mutex<Headless>>`): one
/// request at a time.
public final class SharedHeadless: @unchecked Sendable {
    let lock = NSLock()
    let headless: Headless

    public init(_ headless: Headless) { self.headless = headless }

    public func withLock<T>(_ body: (Headless) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(headless)
    }

    /// Answers one request line under the lock.
    public func respond(_ line: String) -> JSONValue { withLock { $0.respond(line: line) } }
}

/// The JSON-lines control server (photocraft `serve_lines` / `serve_tcp`).
public enum ControlServer {
    /// Serves JSON lines from `reader` until the end, writing each reply with `write`. Blank lines
    /// are ignored; an over-long or non-UTF-8 line gets one error reply (`id: null`) and is skipped,
    /// and the session (with its open documents) keeps serving.
    public static func serveLines(_ h: Headless, reader: LineReader, write: (Data) throws -> Void) throws {
        while true {
            let reply: JSONValue
            var unreadRest = false
            switch try reader.readBoundedLine() {
            case .eof: return
            case .tooLong(_, let endsWithNewline):
                reply = ["id": .null, "ok": false, "error": .string("request exceeds \(ControlSecurity.maxRequestBytes) bytes")]
                unreadRest = !endsWithNewline
            case .invalidUTF8:
                reply = ["id": .null, "ok": false, "error": "request is not valid UTF-8"]
            case .line(let text):
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                reply = h.respond(line: text)
            }
            try write(Budgets.replyLine(reply))
            if unreadRest { try reader.discardRestOfLine() }
        }
    }

    /// Serves `input` until EOF, writing replies to `output` (stdio by default).
    public static func serve(_ h: Headless, input: FileHandle = .standardInput, output: FileHandle = .standardOutput) throws {
        let out = output.fileDescriptor
        Sockets.noSigPipe(out)
        try serveLines(h, reader: LineReader(fd: input.fileDescriptor)) { try Sockets.writeAll(out, $0) }
    }

    /// Answers every line of `text` (tests and scripts): one bounded reply per non-blank line, as
    /// the stdio server would write them.
    public static func respondAll(_ h: Headless, _ text: String) -> [JSONValue] {
        var replies: [JSONValue] = []
        try? serveLines(h, reader: LineReader(data: Data(text.utf8))) { line in
            if let v = try? JSONValue.parse(line) { replies.append(v) }
        }
        return replies
    }

    /// Serves authenticated JSON lines on a loopback TCP address with one shared session until
    /// the process ends (photocraft `serve_tcp`). `ready` gets the bound address.
    public static func serveTCP(_ addr: String, _ shared: SharedHeadless, token: String, ready: (String) -> Void) throws {
        let server = try TCPControlServer(addr, shared, token: token)
        ready(server.localAddress)
        server.run()
    }
}

/// A loopback control listener: refuses non-loopback addresses, caps active connections, and
/// requires the first frame of each connection to authenticate.
public final class TCPControlServer: Sendable {
    let fd: Int32
    let shared: SharedHeadless
    let token: String
    let limiter = ControlSecurity.ConnectionLimiter(max: ControlSecurity.maxConnections)
    let stopped = Atomic<Bool>(false)
    /// The bound address (`127.0.0.1:<port>`).
    public let localAddress: String

    public init(_ addr: String, _ shared: SharedHeadless, token: String) throws {
        let fd = try Sockets.listen(addr)
        let (local, loopback) = Sockets.localAddress(fd)
        if !loopback {
            Darwin.close(fd)
            throw AutomationError.badRequest("\(addr) is not a loopback address")
        }
        self.fd = fd
        self.shared = shared
        self.token = token
        localAddress = local
    }

    deinit { Darwin.close(fd) }

    /// The listener's port.
    public var port: UInt16 { UInt16(Sockets.split(localAddress)?.port ?? "") ?? 0 }

    /// Accepts connections until `stop()`; each is served on its own thread.
    public func run() {
        while !stopped.load(ordering: .relaxed) {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 100) <= 0 { continue }
            let conn = accept(fd, nil, nil)
            if conn < 0 { continue }
            ControlSecurity.configureStream(conn)
            guard let permit = limiter.tryAcquire() else {
                try? Sockets.writeAll(conn, Data(#"{"id":null,"ok":false,"error":"connection limit reached"}"#.utf8 + [0x0A]))
                Darwin.close(conn)
                continue
            }
            let shared = self.shared, token = self.token
            let thread = Thread {
                Self.serveConnection(conn, shared, token: token)
                Darwin.close(conn)
                permit.release()
            }
            thread.start()
        }
    }

    /// Stops accepting (connections already served finish on their own).
    public func stop() { stopped.store(true, ordering: .relaxed) }

    /// Runs `run()` on a background thread.
    public func start() {
        let thread = Thread { self.run() }
        thread.start()
    }

    static func serveConnection(_ conn: Int32, _ shared: SharedHeadless, token: String) {
        let reader = LineReader(fd: conn)
        var authenticated = false
        while true {
            let line: String
            do {
                switch try reader.readBoundedLine() {
                case .eof, .invalidUTF8: return
                case .tooLong:
                    let reply: JSONValue = ["id": .null, "ok": false, "error": .string("request exceeds \(ControlSecurity.maxRequestBytes) bytes")]
                    try? Sockets.writeAll(conn, Budgets.replyLine(reply))
                    return
                case .line(let text):
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    line = text
                }
            } catch {
                return
            }
            let reply: JSONValue
            if authenticated {
                reply = ControlSecurity.repeatAuthReply(line) ?? shared.respond(line)
            } else {
                let (r, ok) = ControlSecurity.authenticationReply(line, expectedToken: token)
                authenticated = ok
                reply = r
            }
            do { try Sockets.writeAll(conn, Budgets.replyLine(reply)) } catch { return }
            if !authenticated { return }
        }
    }
}
