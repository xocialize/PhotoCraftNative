// Port of photocraft-automation (crates/automation/src/bridge.rs `BridgeClient`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// A client for the JSON-lines control protocol (docs/control-protocol.md): one request per line,
// replies matched by `id`, a first-frame `auth` on every connection. It keeps one connection,
// reconnecting after a failure — or before a call, once the connection has been idle long enough
// that the server (which closes idle connections after 30 s) may have closed it. An edit is never
// resent after a transport failure (#1007); only a call the caller vouches is a read gets one
// fresh attempt. It talks to any control server: a desktop app (`--control`) or `pccli serve
// --port`.

import Darwin
import Foundation
import PCDocument
import PCEngine

public final class BridgeClient: Sendable {
    /// The default call timeout sits strictly below the app's 60 s reply deadline, so this
    /// client's error is the one callers see.
    public static let defaultCallTimeout: Double = 55
    /// Reconnect before sending once the connection has been idle this long (below the server's
    /// 30 s idle cutoff, with a margin for a request in flight).
    public static let defaultIdleReconnect: Double = ControlSecurity.ioTimeout - 5

    static let noReplyCauses =
        "the command may still be running, or the app was not drawing frames (display asleep, window fully occluded, or a long operation blocked the frame loop)"

    public let addr: String
    let token: String
    /// Seconds a call may take.
    public let timeout: Double
    let idleReconnect: Double
    let state: State

    /// The connection, touched only on `queue` (one exchange at a time, like photocraft's
    /// `tokio::sync::Mutex`).
    final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "pccli.bridge")
        var conn: Connection?
        var nextID: UInt64 = 1
    }

    final class Connection {
        let fd: Int32
        let reader: LineReader
        let deadline: Deadline
        var lastUsed = Date()
        init(fd: Int32) {
            self.fd = fd
            let deadline = Deadline()
            self.deadline = deadline
            reader = LineReader { buffer in
                while true {
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ms = Int32(max(0, min(Double(Int32.max), deadline.at.timeIntervalSinceNow * 1000)))
                    let ready = poll(&pfd, 1, ms)
                    if ready == 0 { throw TimedOut() }
                    if ready < 0 {
                        if errno == EINTR { continue }
                        throw OSFailure.current
                    }
                    let n = Darwin.read(fd, buffer.baseAddress, buffer.count)
                    if n >= 0 { return n }
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw OSFailure.current
                }
            }
        }
        deinit { Darwin.close(fd) }
    }

    final class Deadline { var at = Date.distantFuture }
    struct TimedOut: Error {}

    /// `addr` such as `127.0.0.1:7878`. Only loopback addresses are accepted, matching the server.
    public init(_ addr: String, token: String) throws {
        let host = addr.lastIndex(of: ":").map { String(addr[..<$0]) } ?? addr
        if !["127.0.0.1", "localhost", "[::1]", "::1"].contains(host) {
            throw AutomationError.badRequest("bridge address must be loopback, got `\(addr)`")
        }
        try ControlSecurity.validateToken(token)
        self.addr = addr
        self.token = token.lowercased()
        timeout = Self.defaultCallTimeout
        idleReconnect = Self.defaultIdleReconnect
        state = State()
    }

    init(addr: String, token: String, timeout: Double, idleReconnect: Double) {
        self.addr = addr
        self.token = token
        self.timeout = timeout
        self.idleReconnect = idleReconnect
        state = State()
    }

    /// The same client with another call timeout (seconds).
    public func withTimeout(_ t: Double) -> BridgeClient { BridgeClient(addr: addr, token: token, timeout: t, idleReconnect: idleReconnect) }

    /// The same client with a shorter idle-reconnect threshold (tests run the reconnect path fast).
    public func withIdleReconnect(_ t: Double) -> BridgeClient { BridgeClient(addr: addr, token: token, timeout: timeout, idleReconnect: t) }

    /// Calls a control method; returns its `result` or the app's error. Never resends after a
    /// transport failure: the request may have been applied (#1007).
    public func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await dispatch(method, params, read: false)
    }

    /// `call` for a method the caller knows only reads state: a transport failure applied
    /// nothing, so one fresh attempt is made on a new connection.
    public func callRead(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await dispatch(method, params, read: true)
    }

    func dispatch(_ method: String, _ params: JSONValue, read: Bool) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, any Error>) in
            state.queue.async {
                cont.resume(with: Result { try self.dispatchSync(method, params, read: read) })
            }
        }
    }

    /// How one attempt failed: it decides the retry and the wording.
    enum Failure: Error {
        /// The connection could not be established or authenticated: nothing was sent.
        case notSent(String)
        /// The request was sent and the reply was lost: the outcome is uncertain.
        case transport(String)
        /// The call's own timeout elapsed; retrying would only double the wait.
        case timedOut
        /// The app answered (ok or error) or the request was refused before it was sent.
        case definite(EngineError)
    }

    func dispatchSync(_ method: String, _ params: JSONValue, read: Bool) throws -> JSONValue {
        switch attempt(method, params) {
        case .success(let v): return v
        case .failure(let f):
            switch f {
            case .notSent, .transport:
                guard read else { throw failure(method, f, read: read) }
                switch attempt(method, params) {
                case .success(let v): return v
                case .failure(let again): throw failure(method, again, read: read)
                }
            default: throw failure(method, f, read: read)
            }
        }
    }

    /// The message for a failed attempt, worded by what the failure proves.
    func failure(_ method: String, _ f: Failure, read: Bool) -> EngineError {
        switch f {
        case .notSent(let e): return AutomationError.bridge("`\(method)` failed: \(e); the request was not sent")
        case .transport(let e):
            return AutomationError.bridge("`\(method)` failed: \(e); operation may have completed; inspect state before retrying")
        case .timedOut:
            let what = read ? "a read may be retried safely" : "operation may have completed; inspect state before retrying"
            return AutomationError.bridge("`\(method)` timed out after \(Self.duration(timeout)); \(Self.noReplyCauses); \(what)")
        case .definite(let e): return e
        }
    }

    /// Rust's `Duration` Debug spelling (`55s`, `300ms`).
    static func duration(_ t: Double) -> String {
        if t < 1 {
            let ms = t * 1000
            return ms == ms.rounded() ? "\(Int(ms))ms" : "\(ms)ms"
        }
        return t == t.rounded() ? "\(Int(t))s" : "\(t)s"
    }

    func takeID() -> UInt64 {
        defer { state.nextID &+= 1 }
        return state.nextID
    }

    /// One exchange over one connection, reconnecting first when the cached one may be dead.
    func attempt(_ method: String, _ params: JSONValue) -> Result<JSONValue, Failure> {
        if let c = state.conn, Date().timeIntervalSince(c.lastUsed) >= idleReconnect {
            // The request below goes to a fresh socket, not one the app may have dropped.
            state.conn = nil
        }
        if state.conn == nil {
            let fd: Int32
            do { fd = try Sockets.connect(addr, timeout: 5) } catch let e as OSFailure {
                if e.code == ETIMEDOUT { return .failure(.notSent("timed out connecting to \(addr)")) }
                return .failure(.notSent("cannot connect to \(addr) (\(e)); start the app with `photocraft --control <port>` and matching control credentials"))
            } catch {
                return .failure(.notSent("cannot connect to \(addr) (\(EngineError.wrap(error))); start the app with `photocraft --control <port>` and matching control credentials"))
            }
            let conn = Connection(fd: fd)
            switch exchange(conn, takeID(), ControlSecurity.authMethod, ["token": .string(token)], timeout: 5) {
            case .timedOut: return .failure(.notSent("control authentication timed out"))
            case .transport(let e): return .failure(.notSent(e))
            case .reply(.success): break
            case .reply(.failure(let e)): return .failure(.definite(e.error))
            }
            state.conn = conn
        }
        let id = takeID()
        guard let conn = state.conn else { return .failure(.notSent("not connected to \(addr)")) }
        switch exchange(conn, id, method, params, timeout: timeout) {
        case .reply(.success(let v)):
            conn.lastUsed = Date()
            return .success(v)
        case .reply(.failure(let e)):
            if e.budget {
                // An oversized frame leaves unread bytes: drop this connection and report the
                // budget failure without retrying a possibly completed edit.
                state.conn = nil
            } else {
                // The app answered: the operation did not apply (except the app's own deadline
                // reply, which fires while the command may still be running).
                conn.lastUsed = Date()
            }
            return .failure(.definite(e.error))
        case .transport(let e):
            // A failed write or lost reply does not prove the edit was not applied.
            state.conn = nil
            return .failure(.transport(e))
        case .timedOut:
            state.conn = nil
            return .failure(.timedOut)
        }
    }

    /// A definite answer that is an error, and whether it was a budget refusal (photocraft's
    /// `BadRequest`), which also drops the connection.
    struct ReplyError: Error {
        var error: EngineError
        var budget: Bool
    }

    enum Exchange {
        case reply(Result<JSONValue, ReplyError>)
        case transport(String)
        case timedOut
    }

    /// Sends one request and reads lines until the reply with its id; stale replies of earlier,
    /// timed-out requests and unparsable lines are skipped.
    func exchange(_ conn: Connection, _ id: UInt64, _ method: String, _ params: JSONValue, timeout: Double) -> Exchange {
        let line = (["id": .int(id), "method": .string(method), "params": params] as JSONValue).serialized() + "\n"
        let size = line.utf8.count
        if size > ControlSecurity.maxRequestBytes {
            return .reply(.failure(ReplyError(error: AutomationError.badRequest("request is \(size) bytes; maximum is \(ControlSecurity.maxRequestBytes)"),
                                              budget: true)))
        }
        conn.deadline.at = Date().addingTimeInterval(timeout)
        defer { conn.deadline.at = .distantFuture }
        do { try Sockets.writeAll(conn.fd, Data(line.utf8)) } catch { return .transport("bridge: \(error)") }
        while true {
            let bytes: [UInt8]
            do { bytes = try conn.reader.readUntilNewline(maximum: Budgets.maxResponseBytes + 1) } catch is TimedOut {
                return .timedOut
            } catch {
                return .transport("bridge: \(error)")
            }
            if bytes.count > Budgets.maxResponseBytes {
                return .reply(.failure(ReplyError(error: AutomationError.badRequest(
                    "bridge response exceeds \(Budgets.maxResponseBytes) bytes; operation may have completed"), budget: true)))
            }
            if bytes.isEmpty { return .transport("bridge: connection closed by the app") }
            guard let v = try? JSONValue.parse(Data(bytes)) else { continue }
            // A stale reply from an earlier, timed-out request.
            if v["id"]?.uint64Value != id { continue }
            if v["ok"]?.boolValue == true { return .reply(.success(v["result"] ?? .null)) }
            return .reply(.failure(ReplyError(error: AutomationError.app(v["error"]?.stringValue ?? "unknown error"), budget: false)))
        }
    }
}
