// Loopback TCP plumbing for photocraft-automation's transports (crates/automation/src/rpc.rs `serve_tcp`, bridge.rs's `TcpStream`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// BSD sockets with the few behaviours the control protocol relies on: loopback-only listeners,
// connect and read deadlines, no SIGPIPE on a peer that went away, and Rust's address spelling
// (`127.0.0.1:7878`, `[::1]:7878`).

import Darwin
import Foundation
import PCEngine

enum Sockets {
    /// `host:port` split at the last colon (`[::1]:7878` → `::1`, 7878).
    static func split(_ addr: String) -> (host: String, port: String)? {
        guard let colon = addr.lastIndex(of: ":") else { return nil }
        var host = String(addr[..<colon])
        let port = String(addr[addr.index(after: colon)...])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (host, port)
    }

    static func resolve(_ addr: String, passive: Bool) throws -> [(family: Int32, address: Data)] {
        guard let (host, port) = split(addr), UInt16(port) != nil else {
            throw AutomationError.io("invalid socket address `\(addr)`")
        }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        if passive { hints.ai_flags = AI_PASSIVE }
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, port, &hints, &res)
        if rc != 0 { throw AutomationError.io("\(addr): \(String(cString: gai_strerror(rc)))") }
        defer { freeaddrinfo(res) }
        var out: [(Int32, Data)] = []
        var p = res
        while let ai = p {
            if let a = ai.pointee.ai_addr { out.append((ai.pointee.ai_family, Data(bytes: a, count: Int(ai.pointee.ai_addrlen)))) }
            p = ai.pointee.ai_next
        }
        return out
    }

    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The bound or peer address as Rust's `SocketAddr` prints it, and whether it is loopback.
    static func describe(_ storage: sockaddr_storage) -> (String, Bool) {
        var s = storage
        if Int32(s.ss_family) == AF_INET {
            return withUnsafePointer(to: &s) { p in
                p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
                    let ip = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    let loop = (UInt32(bigEndian: sin.pointee.sin_addr.s_addr) >> 24) == 127
                    return ("\(ip):\(UInt16(bigEndian: sin.pointee.sin_port))", loop)
                }
            }
        }
        return withUnsafePointer(to: &s) { p in
            p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin in
                var addr = sin.pointee.sin6_addr
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
                let ip = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                return ("[\(ip)]:\(UInt16(bigEndian: sin.pointee.sin6_port))", ip == "::1")
            }
        }
    }

    static func localAddress(_ fd: Int32) -> (String, Bool) {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return describe(storage)
    }

    /// A listening socket on `addr` (photocraft `TcpListener::bind`).
    static func listen(_ addr: String) throws -> Int32 {
        var last = "no address"
        for (family, address) in try resolve(addr, passive: true) {
            let fd = socket(family, SOCK_STREAM, 0)
            if fd < 0 { last = OSFailure.current.description; continue }
            var on: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            let bound = address.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.bind(fd, base.assumingMemoryBound(to: sockaddr.self), socklen_t(address.count))
            }
            if bound == 0 && Darwin.listen(fd, 128) == 0 {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                return fd
            }
            last = OSFailure.current.description
            Darwin.close(fd)
        }
        throw AutomationError.io("bind \(addr): \(last)")
    }

    /// A connected socket, or the error as Rust's `io::Error` prints it.
    static func connect(_ addr: String, timeout: Double) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError = OSFailure(ECONNREFUSED)
        for (family, address) in try resolve(addr, passive: false) {
            let fd = socket(family, SOCK_STREAM, 0)
            if fd < 0 { lastError = .current; continue }
            noSigPipe(fd)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let rc = address.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.connect(fd, base.assumingMemoryBound(to: sockaddr.self), socklen_t(address.count))
            }
            var ok = rc == 0
            if !ok && errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ms = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
                if poll(&pfd, 1, ms) == 1 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    if err == 0 { ok = true } else { lastError = OSFailure(err) }
                } else {
                    lastError = OSFailure(ETIMEDOUT)
                }
            } else if !ok {
                lastError = .current
            }
            if ok {
                _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                return fd
            }
            Darwin.close(fd)
            if lastError.code == ETIMEDOUT { break }
        }
        throw lastError
    }

    /// Writes every byte (a failure is an `OSFailure`).
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        if let e = AuthorizedWorkspace.writeAll(fd, data) { throw e }
    }
}
