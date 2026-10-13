// Port of photocraft-automation's bridge tests (crates/automation/src/bridge.rs `mod tests`, crates/automation/tests/bridge.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The bridge client against scripted fake control servers: reconnect before idle sockets die,
// retry only caller-vouched reads, never resend edits (#1007), never retry timeouts.

import Darwin
import Foundation
@testable import PCAutomation
import PCDocument
import PCEngine
import Synchronization
import Testing

let controlToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

/// A scripted loopback server: each accepted connection runs `handler` on its own thread.
final class FakeServer: Sendable {
    let fd: Int32
    let address: String
    let accepted = Mutex(0)
    let stopped = Atomic<Bool>(false)

    init(maxConnections: Int = .max, _ handler: @escaping @Sendable (_ conn: Int32, _ reader: LineReader, _ index: Int) -> Void) throws {
        fd = try Sockets.listen("127.0.0.1:0")
        address = Sockets.localAddress(fd).0
        let thread = Thread { [self] in
            var served = 0
            while served < maxConnections && !stopped.load(ordering: .relaxed) {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, 50) <= 0 { continue }
                let conn = accept(fd, nil, nil)
                if conn < 0 { continue }
                Sockets.noSigPipe(conn)
                let index = served
                served += 1
                accepted.withLock { $0 += 1 }
                Thread {
                    handler(conn, LineReader(fd: conn), index)
                    close(conn)
                }.start()
            }
        }
        thread.start()
    }

    func stop() { stopped.store(true, ordering: .relaxed) }
    deinit { close(fd) }

    static func readLine(_ reader: LineReader) -> String? {
        guard case .line(let l)? = try? reader.readBoundedLine(maximum: 16 << 20) else { return nil }
        return l
    }

    static func write(_ conn: Int32, _ v: JSONValue) -> Bool { (try? Sockets.writeAll(conn, Data((v.serialized() + "\n").utf8))) != nil }

    /// Reads the auth line and answers it.
    static func authenticate(_ conn: Int32, _ reader: LineReader) -> Bool {
        guard let line = readLine(reader) else { return false }
        let (reply, ok) = ControlSecurity.authenticationReply(line, expectedToken: controlToken)
        return write(conn, reply) && ok
    }
}

/// Collected requests, shared with server threads.
final class Seen: Sendable {
    let requests = Mutex<[JSONValue]>([])
    func add(_ v: JSONValue) { requests.withLock { $0.append(v) } }
    var all: [JSONValue] { requests.withLock { $0 } }
}

@Suite struct BridgeTests {
    @Test func theCallTimeoutStaysBelowTheAppReplyDeadline() {
        // At or above the app's 60 s deadline, callers would see their own cutoff first.
        #expect(BridgeClient.defaultCallTimeout < 60)
    }

    @Test func idleReconnectStaysBelowTheAppIdleCutoff() {
        // Reconnecting later than the I/O timeout would send into a socket the app dropped.
        #expect(BridgeClient.defaultIdleReconnect < ControlSecurity.ioTimeout)
    }

    @Test func readRetriesOnADroppedConnectionAndEditsDoNot() async throws {
        // Each connection serves one request then dies; the next vouched read retries on a fresh
        // connection. The edit, sent after that one also died, must fail with the #1007 wording.
        let seen = Seen()
        let server = try FakeServer(maxConnections: 2) { conn, reader, _ in
            guard FakeServer.authenticate(conn, reader), let line = FakeServer.readLine(reader), let req = try? JSONValue.parse(line) else { return }
            seen.add(req)
            _ = FakeServer.write(conn, ["id": req["id"] ?? .null, "ok": true, "result": ["served": 1]])
        }
        defer { server.stop() }
        let bridge = try BridgeClient(server.address, token: controlToken)
        let first = try await bridge.callRead("document.inspect", .object([:]))
        #expect(first["served"] == 1)
        let retried = try await bridge.callRead("document.inspect", .object([:]))
        #expect(retried["served"] == 1, "connection 2 sees it as its own first request")
        do {
            _ = try await bridge.call("engine.execute", ["command": "layer.new.layer", "params": .object([:])])
            Issue.record("the edit succeeded")
        } catch {
            let e = "\(error)"
            #expect(e.contains("operation may have completed") && e.contains("inspect state before retrying"), "\(e)")
            #expect(!e.contains("retried"), "\(e)")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(seen.all.count == 2, "one request per connection, no edit resend: \(seen.all)")
    }

    @Test func anIdleConnectionIsReplacedBeforeTheNextCall() async throws {
        let seen = Seen()
        let server = try FakeServer(maxConnections: 2) { conn, reader, _ in
            guard FakeServer.authenticate(conn, reader) else { return }
            while let line = FakeServer.readLine(reader), let req = try? JSONValue.parse(line) {
                seen.add(req)
                if !FakeServer.write(conn, ["id": req["id"] ?? .null, "ok": true, "result": ["served": 1]]) { return }
            }
        }
        defer { server.stop() }
        let bridge = try BridgeClient(server.address, token: controlToken).withIdleReconnect(0.1)
        _ = try await bridge.callRead("document.inspect", .object([:]))
        try await Task.sleep(for: .milliseconds(250))
        _ = try await bridge.callRead("document.inspect", .object([:]))
        #expect(server.accepted.withLock { $0 } == 2, "the idle connection was replaced, not reused")
        #expect(seen.all.count == 2)
    }

    @Test func aTimedOutCallIsNotRetried() async throws {
        // The server authenticates but never answers, keeping the connection open: the call hits
        // the client's own timeout, which names the likely causes and is not resent.
        let seen = Seen()
        let server = try FakeServer(maxConnections: 1) { conn, reader, _ in
            guard FakeServer.authenticate(conn, reader) else { return }
            while let line = FakeServer.readLine(reader) { if let req = try? JSONValue.parse(line) { seen.add(req) } }
        }
        defer { server.stop() }
        let bridge = try BridgeClient(server.address, token: controlToken).withTimeout(0.3)
        do {
            _ = try await bridge.callRead("document.inspect", .object([:]))
            Issue.record("answered")
        } catch {
            let e = "\(error)"
            #expect(e.hasPrefix("bridge: "), "\(e)")
            #expect(e.contains("timed out after 300ms"), "\(e)")
            #expect(e.contains("not drawing frames"), "\(e)")
            #expect(e.contains("a read may be retried safely"), "\(e)")
            #expect(!e.contains("may have completed"), "a read timeout never claims an applied edit: \(e)")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen.all.count == 1, "a timed-out call is not resent")
    }

    /// tests/mcp.rs `bridge_response_budget_drops_connection_without_retrying_the_operation`.
    @Test func bridgeResponseBudgetDropsTheConnectionWithoutRetrying() async throws {
        let server = try FakeServer(maxConnections: 2) { conn, reader, index in
            if index > 0 { return }
            guard FakeServer.authenticate(conn, reader), FakeServer.readLine(reader) != nil else { return }
            // The read limit cuts this multi-byte character in half: still a budget error.
            var oversized = [UInt8](repeating: 0x78, count: Budgets.maxResponseBytes)
            oversized += Array("é".utf8)
            try? Sockets.writeAll(conn, Data(oversized))
            usleep(300_000)
        }
        defer { server.stop() }
        let bridge = try BridgeClient(server.address, token: controlToken)
        do {
            _ = try await bridge.call("engine.execute", ["command": "command.list"])
            Issue.record("answered")
        } catch {
            #expect("\(error)".contains("bridge response exceeds"), "\(error)")
        }
        #expect(server.accepted.withLock { $0 } == 1, "an oversized reply must not retry the operation")
    }

    /// tests/mcp.rs `bridge_lost_reply_does_not_replay_an_edit_and_next_call_reconnects`, against
    /// a real headless session behind the fake server.
    @Test func bridgeLostReplyDoesNotReplayAnEditAndTheNextCallReconnects() async throws {
        let backend = SharedHeadless(Headless())
        _ = try backend.withLock { try $0.handle("doc.new", ["width": 8, "height": 8]) }
        let initial = backend.withLock { ($0.session.active?.doc.layerCount ?? 0, $0.session.active?.history.pastCount ?? 0) }
        let seen = Seen()
        let server = try FakeServer(maxConnections: 2) { conn, reader, index in
            guard FakeServer.authenticate(conn, reader), let line = FakeServer.readLine(reader), let req = try? JSONValue.parse(line) else { return }
            seen.add(req["params"]?["command"] ?? .null)
            let result = backend.withLock { (try? $0.handle(req["method"]?.stringValue ?? "", req["params"] ?? .null)) ?? .null }
            // The edit has completed, but the connection closes before its reply.
            if index == 0 { return }
            _ = FakeServer.write(conn, ["id": req["id"] ?? .null, "ok": true, "result": result])
        }
        defer { server.stop() }
        let bridge = try BridgeClient(server.address, token: controlToken)
        do {
            _ = try await bridge.call("engine.execute", ["command": "layer.new.layer", "params": ["name": "Once"]])
            Issue.record("the lost reply was reported as success")
        } catch {
            #expect("\(error)".contains("operation may have completed") && "\(error)".contains("inspect"), "\(error)")
        }
        let document = try await bridge.call("engine.execute", ["command": "document.inspect"])
        #expect(document["layers"]?.arrayValue?.count == 2)
        #expect(seen.all == ["layer.new.layer", "document.inspect"])
        let now = backend.withLock { ($0.session.active?.doc.layerCount ?? 0, $0.session.active?.history.pastCount ?? 0) }
        #expect(now.0 == initial.0 + 1, "the edit was applied once")
        #expect(now.1 == initial.1 + 1, "one undo step")
    }

    @Test func bridgeRejectsNonLoopbackAndBadTokens() throws {
        #expect(throws: EngineError.self) { try BridgeClient("10.0.0.5:7878", token: controlToken) }
        _ = try BridgeClient("127.0.0.1:7878", token: controlToken)
        _ = try BridgeClient("localhost:1", token: controlToken)
        _ = try BridgeClient("[::1]:1", token: controlToken)
        #expect(throws: EngineError.self) { try BridgeClient("localhost:1", token: "short") }
    }

    /// The bridge talks to pccli's own TCP server end to end.
    @Test func bridgeDrivesAHeadlessTCPServer() async throws {
        let server = try TCPControlServer("127.0.0.1:0", SharedHeadless(Headless()), token: controlToken)
        server.start()
        defer { server.stop() }
        let bridge = try BridgeClient(server.localAddress, token: controlToken)
        _ = try await bridge.call("doc.new", ["width": 8, "height": 8])
        let listed = try await bridge.callRead("session.list", .object([:]))
        #expect(listed["documents"]?.arrayValue?.count == 1)
        do {
            _ = try await bridge.call("doc.open", ["path": "/etc/passwd"])
            Issue.record("opened")
        } catch {
            #expect("\(error)".hasPrefix("app: "), "\(error)")
        }
    }
}
