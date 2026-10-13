// Port of photocraft-automation (crates/automation/src/security.rs: limits, bounded line reads, control tokens, first-frame authentication, the connection limiter), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Shared security primitives for the JSON-lines control transports: a request line is never
// buffered past 1 MiB (plus one byte), the first TCP frame must authenticate with a 256-bit
// bearer token compared in constant time, and a listener services at most 16 connections.

import Darwin
import Foundation
import PCDocument
import Security
import PCEngine
import Synchronization

public enum ControlSecurity {
    /// The first request on every TCP connection must use this method.
    public static let authMethod = "auth"
    /// Maximum encoded JSON request line, including its newline.
    public static let maxRequestBytes = 1 << 20
    /// Maximum simultaneously serviced TCP connections per listener.
    public static let maxConnections = 16
    /// Maximum commands or method calls in one batch.
    public static let maxBatchSteps = 256
    /// Idle/read and write timeout for loopback TCP connections, in seconds.
    public static let ioTimeout: Double = 30

    static let tokenBytes = 32
    static let tokenHexLength = tokenBytes * 2

    // MARK: Tokens

    /// A 256-bit bearer token from the operating system's CSPRNG (`SecRandomCopyBytes`), as 64 lowercase hex
    /// digits.
    public static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenBytes)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, raw.count, base)
        }
        if status != errSecSuccess { throw AutomationError.other("cannot generate control token: OSStatus \(status)") }
        let hex = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(tokenHexLength)
        for b in bytes {
            out.append(hex[Int(b >> 4)])
            out.append(hex[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Accepts only the fixed-width hexadecimal form `generateToken` emits.
    public static func validateToken(_ token: String) throws {
        if token.utf8.count != tokenHexLength || !token.utf8.allSatisfy(isHexDigit) {
            throw AutomationError.badRequest("control token must contain exactly 64 hexadecimal characters")
        }
    }

    static func isHexDigit(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }

    /// Compares fixed-width tokens without an early exit on a mismatching byte.
    public static func tokenMatches(_ expected: String, _ supplied: String) -> Bool {
        let a = Array(expected.utf8), b = Array(supplied.utf8)
        if a.count != tokenHexLength || b.count != tokenHexLength { return false }
        var different: UInt8 = 0
        for i in 0..<tokenHexLength { different |= a[i] ^ b[i] }
        return different == 0
    }

    /// Validates the first TCP frame without exposing any control method before authentication:
    /// the reply, and whether the connection is now authenticated.
    public static func authenticationReply(_ line: String, expectedToken: String) -> (JSONValue, Bool) {
        guard let req = try? JSONValue.parse(line) else {
            return (["id": .null, "ok": false, "error": "authentication required"], false)
        }
        let id = req["id"] ?? .null
        let supplied = req["params"]?["token"]?.stringValue ?? ""
        let ok = req["method"]?.stringValue == authMethod && tokenMatches(expectedToken, supplied)
        if ok { return (["id": id, "ok": true, "result": ["authenticated": true]], true) }
        return (["id": id, "ok": false, "error": "authentication required"], false)
    }

    /// The reply to a repeat `auth` frame on an authenticated connection; nil for any other frame,
    /// which the caller dispatches as usual.
    public static func repeatAuthReply(_ line: String) -> JSONValue? {
        guard let req = try? JSONValue.parse(line), req["method"]?.stringValue == authMethod else { return nil }
        return ["id": req["id"] ?? .null, "ok": false, "error": "already authenticated"]
    }

    static func readTokenFile(_ path: String) throws -> String {
        let text: String
        do { text = try String(contentsOfFile: path, encoding: .utf8) } catch {
            throw TokenFileMissing(path: path, message: AutomationError.io("\(path): \(Self.ioMessage(error))"))
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateToken(token)
        return token
    }

    /// A token file that could not be read (photocraft's `AutomationError::Io` from
    /// `read_token_file`): the server then creates it when it does not exist.
    struct TokenFileMissing: Error {
        var path: String
        var message: EngineError
    }

    static func ioMessage(_ error: any Error) -> String {
        let ns = error as NSError
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain {
            return OSFailure(Int32(posix.code)).description
        }
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError) {
            return OSFailure(ENOENT).description
        }
        return ns.localizedDescription
    }

    static func createTokenFile(_ path: String, _ token: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            do { try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true) } catch {
                throw AutomationError.io("\(parent): \(ioMessage(error))")
            }
        }
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd < 0 { throw TokenFileMissing(path: path, message: AutomationError.io("\(path): \(OSFailure.current)")) }
        defer { Darwin.close(fd) }
        if let e = AuthorizedWorkspace.writeAll(fd, Data((token + "\n").utf8)) { throw AutomationError.io("\(path): \(e)") }
    }

    /// Resolves a server token. With no supplied token or file a fresh token is returned; a
    /// missing token file is created atomically (mode 0600) and an existing one is read and
    /// validated.
    public static func serverToken(supplied: String?, tokenFile: String?) throws -> String {
        if supplied != nil && tokenFile != nil {
            throw AutomationError.badRequest("use either a control token or a control token file, not both")
        }
        if let supplied {
            try validateToken(supplied)
            return supplied.lowercased()
        }
        let token = try generateToken()
        guard let path = tokenFile else { return token }
        do {
            return try readTokenFile(path).lowercased()
        } catch let missing as TokenFileMissing {
            if FileManager.default.fileExists(atPath: path) { throw missing.message }
            do {
                try createTokenFile(path, token)
                return token
            } catch let lost as TokenFileMissing {
                // Another process won the create-new race.
                if FileManager.default.fileExists(atPath: path) { return try readTokenFile(path).lowercased() }
                throw lost.message
            }
        }
    }

    /// Resolves the token a client uses. Clients never silently generate credentials.
    public static func clientToken(supplied: String?, tokenFile: String?) throws -> String {
        if supplied != nil && tokenFile != nil {
            throw AutomationError.badRequest("use either a control token or a control token file, not both")
        }
        if let supplied {
            try validateToken(supplied)
            return supplied.lowercased()
        }
        guard let path = tokenFile else {
            throw AutomationError.badRequest(
                "bridge mode needs --control-token, --control-token-file, PHOTOCRAFT_CONTROL_TOKEN, or PHOTOCRAFT_CONTROL_TOKEN_FILE")
        }
        do { return try readTokenFile(path).lowercased() } catch let missing as TokenFileMissing { throw missing.message }
    }

    /// Environment-aware token inputs shared by the CLI's server and bridge.
    public static func tokenInputs(supplied: String?, tokenFile: String?,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> (String?, String?) {
        (supplied ?? environment["PHOTOCRAFT_CONTROL_TOKEN"], tokenFile ?? environment["PHOTOCRAFT_CONTROL_TOKEN_FILE"])
    }

    // MARK: Connections

    /// Counts active connections and hands out a permit only below the maximum.
    public final class ConnectionLimiter: Sendable {
        let active = Mutex(0)
        public let max: Int
        public init(max: Int) { self.max = max }

        public func tryAcquire() -> ConnectionPermit? {
            let ok = active.withLock { n -> Bool in
                if n >= max { return false }
                n += 1
                return true
            }
            return ok ? ConnectionPermit(self) : nil
        }

        public var count: Int { active.withLock { $0 } }
    }

    /// Holds one connection slot until released (or dropped).
    public final class ConnectionPermit: Sendable {
        let limiter: ConnectionLimiter
        let released = Mutex(false)
        init(_ limiter: ConnectionLimiter) { self.limiter = limiter }
        public func release() {
            let first = released.withLock { r -> Bool in
                defer { r = true }
                return !r
            }
            if first { limiter.active.withLock { $0 -= 1 } }
        }
        deinit { release() }
    }

    /// Applies the idle and write timeouts to a socket before a connection worker uses it.
    static func configureStream(_ fd: Int32) {
        var tv = timeval(tv_sec: Int(ioTimeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
}

// MARK: - Bounded line reads

/// One line read by `LineReader.readBoundedLine` (photocraft `LineRead`, with the line).
public enum BoundedLine: Equatable, Sendable {
    case eof
    /// A complete line within the limit, with its newline when it had one.
    case line(String)
    /// More than the limit: `bytes` were read (limit + 1); the rest of the line is unread unless
    /// `endsWithNewline`.
    case tooLong(bytes: Int, endsWithNewline: Bool)
    /// A line within the limit that is not UTF-8; the whole line was consumed.
    case invalidUTF8
}

/// A buffered byte reader over a file descriptor, a socket or bytes in memory (Rust's `BufRead`),
/// with the bounded line reads of photocraft's transports.
public final class LineReader {
    let source: (UnsafeMutableRawBufferPointer) throws -> Int
    var buffer: [UInt8] = []
    var position = 0
    var finished = false

    /// `read` fills the buffer it is given and returns the count, 0 at the end.
    public init(read: @escaping (UnsafeMutableRawBufferPointer) throws -> Int) { source = read }

    /// Reads a file descriptor (stdin, a pipe, a socket); `EINTR` is retried.
    public convenience init(fd: Int32) {
        self.init { buffer in
            while true {
                let n = Darwin.read(fd, buffer.baseAddress, buffer.count)
                if n >= 0 { return n }
                if errno == EINTR { continue }
                throw OSFailure.current
            }
        }
    }

    /// Reads bytes in memory, `chunk` at a time (tests use small chunks to split lines).
    public convenience init(data: Data, chunk: Int = 64 << 10) {
        var offset = 0
        let bytes = [UInt8](data)
        self.init { buffer in
            let n = min(chunk, buffer.count, bytes.count - offset)
            if n <= 0 { return 0 }
            bytes.withUnsafeBytes { src in buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset..<offset + n])) }
            offset += n
            return n
        }
    }

    /// The buffered bytes, reading more when none are left; empty at the end.
    func fill() throws -> ArraySlice<UInt8> {
        if position < buffer.count { return buffer[position...] }
        if finished { return [] }
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        let n = try chunk.withUnsafeMutableBytes { try source($0) }
        if n <= 0 {
            finished = true
            buffer = []
            position = 0
            return []
        }
        buffer = Array(chunk[..<n])
        position = 0
        return buffer[...]
    }

    func consume(_ n: Int) { position = min(position + n, buffer.count) }

    /// Reads one line without ever buffering more than `maximum` plus one byte (photocraft
    /// `read_bounded_line`).
    public func readBoundedLine(maximum: Int = ControlSecurity.maxRequestBytes) throws -> BoundedLine {
        var bytes: [UInt8] = []
        let limit = maximum + 1
        while bytes.count < limit {
            let available = try fill()
            if available.isEmpty { break }
            let room = limit - bytes.count
            let window = available.prefix(room)
            if let nl = window.firstIndex(of: 0x0A) {
                let take = nl - available.startIndex + 1
                bytes.append(contentsOf: available.prefix(take))
                consume(take)
                break
            }
            bytes.append(contentsOf: window)
            consume(window.count)
        }
        if bytes.isEmpty { return .eof }
        if bytes.count > maximum { return .tooLong(bytes: bytes.count, endsWithNewline: bytes.last == 0x0A) }
        guard let text = String(validating: bytes, as: UTF8.self) else { return .invalidUTF8 }
        return .line(text)
    }

    /// Skips the rest of the current line (through its newline, or to the end) without buffering
    /// it (photocraft `discard_rest_of_line`).
    public func discardRestOfLine() throws {
        while true {
            let available = try fill()
            if available.isEmpty { return }
            if let nl = available.firstIndex(of: 0x0A) {
                consume(nl - available.startIndex + 1)
                return
            }
            consume(available.count)
        }
    }

    /// Reads raw bytes up to and including a newline, at most `maximum` bytes (the bridge's reply
    /// reads); empty at the end.
    func readUntilNewline(maximum: Int) throws -> [UInt8] {
        var bytes: [UInt8] = []
        while bytes.count < maximum {
            let available = try fill()
            if available.isEmpty { break }
            let window = available.prefix(maximum - bytes.count)
            if let nl = window.firstIndex(of: 0x0A) {
                let take = nl - available.startIndex + 1
                bytes.append(contentsOf: available.prefix(take))
                consume(take)
                return bytes
            }
            bytes.append(contentsOf: window)
            consume(window.count)
        }
        return bytes
    }
}
