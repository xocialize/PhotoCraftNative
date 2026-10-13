// Port of photocraft-automation (crates/automation/src/server/transport.rs `serve_io`, `bounded_line`; server/conventions.rs's list envelopes), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// MCP over a JSON-lines stream (stdio). Each request line is read whole and bounded (1 MiB)
// before any of it reaches the SDK — a valid JSON prefix can never run when an oversized suffix
// is refused; an oversized or non-UTF-8 line ends the session with an error. A malformed line gets
// a -32700 reply with `id: null` and the next line is still served. Lines go to the SDK server
// through an in-memory transport pair, and one writer serialises the SDK's replies and the parse
// errors. List and read results carry photocraft's result envelope fields (`resultType`,
// `ttlMs`, `cacheScope`). At the end of input, requests already received are answered before the
// session closes.

import Foundation
import MCP
import PCDocument
import PCEngine
import Synchronization

extension LineReader {
    /// photocraft `bounded_line`: one request line (newline and a trailing `\r` stripped), the
    /// last unterminated line at the end, nil at the end; a line longer than `maximum` bytes
    /// (newline included) or not UTF-8 is an error.
    public func readMCPLine(maximum: Int = ControlSecurity.maxRequestBytes) throws -> String? {
        var bytes = try readUntilNewline(maximum: maximum + 1)
        if bytes.isEmpty { return nil }
        if bytes.count > maximum { throw AutomationError.io("request exceeds \(maximum) bytes") }
        if bytes.last == 0x0A {
            bytes.removeLast()
            if bytes.last == 0x0D { bytes.removeLast() }
        }
        guard let text = String(validating: bytes, as: UTF8.self) else { throw AutomationError.io("stream did not contain valid UTF-8") }
        return text
    }
}

extension PhotocraftMCP {
    /// What the pump knows about requests in flight.
    final class Pump: Sendable {
        struct State {
            /// Requests received and not yet answered, by their id's JSON.
            var outstanding: Set<String> = []
            /// List and read requests, whose results get photocraft's envelope fields.
            var envelopes: [String: Int] = [:]
        }
        let state = Mutex(State())
        let writeLock = Mutex(())
        let write: @Sendable (Data) -> Void

        init(write: @escaping @Sendable (Data) -> Void) { self.write = write }

        func emit(_ line: Data) {
            var d = line
            d.append(0x0A)
            writeLock.withLock { _ in write(d) }
        }

        func incoming(_ v: JSONValue) {
            guard let method = v["method"]?.stringValue else { return }
            if method == "notifications/cancelled", let id = v["params"]?["requestId"] {
                state.withLock { _ = $0.outstanding.remove(id.serialized()) }
                return
            }
            guard let id = v["id"], id != .null else { return }
            let key = id.serialized()
            state.withLock { s in
                s.outstanding.insert(key)
                switch method {
                case "tools/list", "resources/list", "prompts/list", "resources/templates/list": s.envelopes[key] = 600_000
                case "resources/read": s.envelopes[key] = 0
                default: break
                }
            }
        }

        /// The reply as written: a list or read result gains `resultType`, `ttlMs` and
        /// `cacheScope`.
        func outgoing(_ data: Data) -> Data {
            guard let v = try? JSONValue.parse(data), let id = v["id"], id != .null, v["result"] != nil || v["error"] != nil else { return data }
            let key = id.serialized()
            let ttl = state.withLock { s -> Int? in
                s.outstanding.remove(key)
                return s.envelopes.removeValue(forKey: key)
            }
            guard let ttl, var result = v["result"]?.objectValue else { return data }
            result["resultType"] = "complete"
            result["ttlMs"] = .int(ttl)
            result["cacheScope"] = "private"
            return Data(v.setting("result", .object(result)).serialized().utf8)
        }

        var idle: Bool { state.withLock { $0.outstanding.isEmpty } }
    }

    enum PumpEvent: Sendable {
        case line(String)
        case failed(EngineError)
    }

    /// Serves MCP over a JSON-lines stream until the input ends (photocraft `serve_io`). An
    /// oversized or undecodable line ends the session with its error.
    public func serveIO(reader: LineReader, write: @escaping @Sendable (Data) -> Void) async throws {
        let server = await makeServer()
        let (client, serverSide) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverSide)
        try await client.connect()
        let pump = Pump(write: write)
        let replies = await client.receive()
        let writer = Task {
            do { for try await data in replies { pump.emit(pump.outgoing(data)) } } catch {}
        }
        let (events, continuation) = AsyncStream<PumpEvent>.makeStream()
        let box = ReaderBox(reader)
        let thread = Thread {
            while true {
                do {
                    guard let line = try box.reader.readMCPLine() else { break }
                    continuation.yield(.line(line))
                } catch {
                    continuation.yield(.failed(EngineError.wrap(error)))
                    break
                }
            }
            continuation.finish()
        }
        thread.start()
        var failure: EngineError?
        for await event in events {
            switch event {
            case .line(let text):
                if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let v: JSONValue
                do { v = try JSONValue.parse(text) } catch {
                    let reply: JSONValue = ["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": .string("parse error: \(error)")]]
                    pump.emit(Data(reply.serialized().utf8))
                    continue
                }
                pump.incoming(v)
                try? await client.send(Data(text.utf8))
            case .failed(let e):
                failure = e
            }
            if failure != nil { break }
        }
        // Requests already received are answered before the session closes.
        if failure == nil {
            while !pump.idle { try? await Task.sleep(for: .milliseconds(5)) }
        }
        await client.disconnect()
        await server.stop()
        await writer.value
        if let failure { throw failure }
    }

    /// Serves MCP on stdin/stdout until the client disconnects.
    public func serveStdio() async throws {
        let out = FileHandle.standardOutput.fileDescriptor
        Sockets.noSigPipe(out)
        try await serveIO(reader: LineReader(fd: FileHandle.standardInput.fileDescriptor)) { data in
            try? Sockets.writeAll(out, data)
        }
    }
}

/// Hands a reader (used by one thread at a time) to the reading thread.
final class ReaderBox: @unchecked Sendable {
    let reader: LineReader
    init(_ reader: LineReader) { self.reader = reader }
}
