// Port of photocraft-automation (crates/automation/src/workspace.rs: `AuthorizedWorkspace`, `request_path`, `relative_path`, `read_to_observed_length`, `ExportSequence`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Capability-scoped file access for untrusted automation (the control channel and MCP). Each
// launch-time root is held open as a directory descriptor, and every request path is resolved
// beneath it by the kernel (`openat` with `O_RESOLVE_BENEATH`, `renameatx_np` with
// `RENAME_RESOLVE_BENEATH`): the Darwin counterpart of cap-std's `Dir`, so a symbolic link that
// leads outside the root is refused while one that stays inside is followed. Request paths are
// validated as text before any file effect (no parent traversal, alternate separators, prefixes,
// device names, empty or `.` components); an absolute path is accepted only when its text names
// a file beneath the root. Writes are atomic (temporary file, flush, rename); reads never trust
// the file's metadata length; exports own only the files they create.

import Darwin
import Foundation
import PCDocument
import PCEngine
import PCFormat
import Synchronization

/// Independent read and write directory capabilities for automation.
public struct AuthorizedWorkspace: Sendable, Equatable {
    /// One open root directory and its textual absolute path (trusted launch configuration).
    final class Root: Sendable {
        let fd: Int32
        let path: String
        init(fd: Int32, path: String) {
            self.fd = fd
            self.path = path
        }
        deinit { Darwin.close(fd) }
    }

    let read: Root?
    let write: Root?

    /// The read root as configured (absolute, links not resolved), when granted.
    public var readRoot: URL? { read.map { URL(fileURLWithPath: $0.path) } }
    /// The write root as configured (absolute, links not resolved), when granted.
    public var writeRoot: URL? { write.map { URL(fileURLWithPath: $0.path) } }

    /// No authority at all (photocraft `AuthorizedWorkspace::default()`): everything fails closed.
    public init() {
        read = nil
        write = nil
    }

    /// Opens the configured roots as capabilities. Either authority may be omitted; omitted
    /// authority fails closed.
    public init(readRoot: String? = nil, writeRoot: String? = nil) throws {
        read = try Self.openRoot(readRoot, "read")
        write = try Self.openRoot(writeRoot, "write")
    }

    public static func == (a: AuthorizedWorkspace, b: AuthorizedWorkspace) -> Bool {
        a.read?.path == b.read?.path && a.write?.path == b.write?.path
    }

    static func openRoot(_ path: String?, _ authority: String) throws -> Root? {
        guard let path else { return nil }
        if path.isEmpty { throw AutomationError.badRequest("automation \(authority) root is empty") }
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { throw AutomationError.io("cannot open automation \(authority) root `\(path)`: \(OSFailure.current)") }
        // Textual (no link resolution), like the request paths it is compared with.
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            absolute = cwd.hasSuffix("/") ? cwd + path : cwd + "/" + path
        }
        return Root(fd: fd, path: absolute)
    }

    // MARK: Request paths

    /// `std::path::Path::components` of a Unix path, as text: empty and `.` components dropped
    /// (a leading `.` of a relative path kept), `..` kept.
    static func components(_ path: String) -> [String] {
        var out: [String] = []
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        for (i, p) in parts.enumerated() {
            if p.isEmpty { continue }
            if p == "." && !(i == 0 && !path.hasPrefix("/")) { continue }
            out.append(String(p))
        }
        return out
    }

    /// A request path as the relative path the root's capability resolves (photocraft
    /// `request_path`). An absolute path is accepted only when its text names a file beneath
    /// `root`: the root's components are stripped and the rest must pass `relativePath`.
    /// Nothing is resolved on the filesystem.
    static func requestPath(_ raw: String, _ root: Root?) throws -> String {
        guard let root, raw.hasPrefix("/") else { return try relativePath(raw) }
        let want = components(root.path)
        var got = components(raw)[...]
        for w in want {
            guard let g = got.first, g == w else { throw pathError(raw, "absolute paths must be inside the automation root") }
            got = got.dropFirst()
        }
        return try relativePath(got.joined(separator: "/"))
    }

    /// photocraft `relative_path`: a non-empty, forward-slash relative path of plain components.
    static func relativePath(_ raw: String) throws -> String {
        if raw.isEmpty { throw pathError(raw, "path is empty") }
        if raw.contains("\\") { throw pathError(raw, "alternate separators are not allowed; use `/`") }
        if raw.hasPrefix("/") { throw pathError(raw, "absolute paths are not allowed") }
        if raw.contains(":") { throw pathError(raw, "drive, device and stream prefixes are not allowed") }
        for c in raw.split(separator: "/", omittingEmptySubsequences: false) {
            if c.isEmpty { throw pathError(raw, "empty path components are not allowed") }
            if c == "." { throw pathError(raw, "`.` path components are not allowed") }
            if c == ".." { throw pathError(raw, "parent traversal is not allowed") }
            if c.hasSuffix(".") || c.hasSuffix(" ") { throw pathError(raw, "path components ending in a dot or space are not allowed") }
            if isWindowsDeviceName(String(c)) { throw pathError(raw, "reserved device names are not allowed") }
        }
        return raw
    }

    static func isWindowsDeviceName(_ component: String) -> Bool {
        let stem = (component.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? component).uppercased()
        if ["CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$"].contains(stem) { return true }
        for prefix in ["COM", "LPT"] where stem.hasPrefix(prefix) {
            let n = stem.dropFirst(prefix.count)
            if n.count == 1, let d = n.first, ("1"..."9").contains(d) { return true }
        }
        return false
    }

    static func pathError(_ path: String, _ reason: String) -> EngineError {
        AutomationError.badRequest("automation path rejected: \(reason): `\(path)`")
    }

    static func fileError(_ operation: String, _ path: String, _ error: OSFailure) -> EngineError {
        AutomationError.io("automation \(operation) `\(path)` failed (\(error.kind)): \(error)")
    }

    // MARK: Reading

    /// Reads one regular file below the configured read root.
    public func read(_ path: String) throws -> Data {
        let relative = try Self.requestPath(path, read)
        guard let root = read else { throw AutomationError.absent("read") }
        // Non-blocking open: a FIFO or device must not stall before it is refused.
        let fd = openat(root.fd, relative, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_RESOLVE_BENEATH)
        if fd < 0 { throw Self.fileError("read", path, .current) }
        defer { Darwin.close(fd) }
        var st = stat()
        if fstat(fd, &st) != 0 { throw Self.fileError("read", path, .current) }
        if (st.st_mode & S_IFMT) != S_IFREG {
            throw AutomationError.badRequest("automation read path is not a regular file: `\(path)`")
        }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        let bytes = try Self.readToObservedLength(observedLength: UInt64(max(0, st.st_size))) { buffer in
            while true {
                let n = Darwin.read(fd, buffer.baseAddress, buffer.count)
                if n >= 0 { return n }
                if errno == EINTR { continue }
                throw OSFailure.current
            }
        }
        return Data(bytes)
    }

    /// photocraft `read_to_observed_length`: reads in chunks without reserving from a possibly
    /// stale or hostile metadata length, and refuses growth beyond the length observed on the
    /// opened file. `read` fills the buffer it is given and returns the count (0 at the end).
    static func readToObservedLength(observedLength: UInt64, _ read: (UnsafeMutableRawBufferPointer) throws -> Int) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let remaining = observedLength &- min(observedLength, UInt64(bytes.count))
            let ask = remaining >= UInt64(chunk.count) ? chunk.count : Int(remaining) + 1
            let n: Int
            do {
                n = try chunk.withUnsafeMutableBytes { try read(UnsafeMutableRawBufferPointer(rebasing: $0[..<ask])) }
            } catch {
                throw AutomationError.io("automation read failed: \(error)")
            }
            if n <= 0 { return bytes }
            if UInt64(n) > remaining {
                throw AutomationError.badRequest("automation file grew beyond its observed length of \(observedLength) bytes")
            }
            bytes.append(contentsOf: chunk[..<n])
        }
    }

    /// photocraft `open_pcraft`: a `.pcraft` document in directory form below the read root.
    /// A regular file at the path is `nil` (the caller reads it as bytes). Every bundle entry is
    /// opened beneath the root by the kernel (`O_RESOLVE_BENEATH`), so an entry that is a link
    /// leading outside is refused, and only regular files are read.
    public func openPcraft(_ path: String) throws -> Document? {
        let relative = try Self.requestPath(path, read)
        guard let root = read else { throw AutomationError.absent("read") }
        let fd = openat(root.fd, relative, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_RESOLVE_BENEATH)
        if fd < 0 {
            let e = OSFailure.current
            if e.code == ENOTDIR { return nil }
            throw Self.fileError("read", path, e)
        }
        Darwin.close(fd)
        do {
            var doc = try PcraftFormat.load(from: BundleSource(root: root, bundle: relative))
            doc.name = (path as NSString).lastPathComponent
            return doc
        } catch {
            throw AutomationError.other("automation read `\(path)` failed: \(error)")
        }
    }

    /// The entries of a directory bundle beneath the read root.
    struct BundleSource: ByteSource {
        let root: Root
        let bundle: String

        func get(_ path: String, max: Int) throws(FormatError) -> [UInt8] {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw .corrupt("bad bundle entry `\(path)`") }
            let fd = openat(root.fd, "\(bundle)/\(path)", O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_RESOLVE_BENEATH)
            if fd < 0 { throw .io(IOError(errno: errno, path)) }
            defer { Darwin.close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw .corrupt("\(path): not a regular file") }
            if st.st_size > max { throw .limitExceeded("\(path) is larger than \(max) bytes") }
            var out = [UInt8](repeating: 0, count: Int(st.st_size))
            var got = 0
            while got < out.count {
                let n = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, $0.count - got) }
                if n < 0 { if errno == EINTR { continue }; throw .io(IOError(errno: errno, path)) }
                if n == 0 { break }
                got += n
            }
            return Array(out[..<got])
        }
    }

    /// Whether `path` names an existing entry beneath the read root.
    func exists(_ path: String) -> Bool {
        guard let root = read, let relative = try? Self.requestPath(path, read) else { return false }
        var st = stat()
        return fstatat(root.fd, relative, &st, AT_RESOLVE_BENEATH) == 0
    }

    // MARK: Writing

    /// Creates or replaces one file below the configured write root, crash-safely: the bytes go
    /// to a temporary file beside the target, which is flushed and renamed over it (photocraft
    /// `atomic_write`, through the directory capability). On failure the previous file is
    /// untouched and the temporary file is removed. The parent directory must already exist.
    public func write(_ path: String, _ data: Data) throws {
        let relative = try Self.requestPath(path, write)
        guard let root = write else { throw AutomationError.absent("write") }
        let parts = relative.split(separator: "/").map(String.init)
        let leaf = parts.last ?? relative
        let parent = parts.dropLast().joined(separator: "/")
        let tmp = parent.isEmpty ? Self.tempName(leaf) : parent + "/" + Self.tempName(leaf)
        let fd = openat(root.fd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_RESOLVE_BENEATH, 0o666)
        if fd < 0 { throw Self.fileError("write", path, .current) }
        var failure: OSFailure?
        if let e = Self.writeAll(fd, data) ?? Self.syncFile(fd) { failure = e }
        Darwin.close(fd)
        if failure == nil, renameatx_np(root.fd, tmp, root.fd, relative, UInt32(RENAME_RESOLVE_BENEATH)) != 0 {
            failure = .current
        }
        if let failure {
            _ = unlinkat(root.fd, tmp, 0)
            throw Self.fileError("write", path, failure)
        }
        // Flush the directory entry; best effort, the new bytes are already in place.
        let dir = openat(root.fd, parent.isEmpty ? "." : parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_RESOLVE_BENEATH)
        if dir >= 0 {
            _ = Self.syncFile(dir)
            Darwin.close(dir)
        }
    }

    /// photocraft `atomic::temp_name`: a short hidden name unique to this process and call.
    static func tempName(_ file: String) -> String {
        let n = tempCounter.add(1, ordering: .relaxed).oldValue
        return ".\(String(file.prefix(64))).\(getpid())-\(n).pcsave.tmp"
    }

    static let tempCounter = Atomic<UInt64>(0)

    static func writeAll(_ fd: Int32, _ data: Data) -> OSFailure? {
        data.withUnsafeBytes { raw -> OSFailure? in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress.map { $0 + offset }, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return .current
                }
                offset += n
            }
            return nil
        }
    }

    /// photocraft `atomic::sync_file`: a full flush, or `fsync` on file systems that refuse one.
    static func syncFile(_ fd: Int32) -> OSFailure? {
        if fcntl(fd, F_FULLFSYNC) == 0 { return nil }
        let e = errno
        if [ENOTSUP, EINVAL, ENOTTY, EOPNOTSUPP].contains(e) { return fsync(fd) == 0 ? nil : .current }
        return OSFailure(e)
    }

    // MARK: Export sequences

    /// An export into `path` (created beneath the write root as needed) that owns only the files
    /// it creates (photocraft `export_sequence`).
    public func exportSequence(_ path: String) throws -> ExportSequence {
        let relative = try Self.requestPath(path, write)
        guard let root = write else { throw AutomationError.absent("write") }
        let parts = relative.split(separator: "/").map(String.init)
        for i in parts.indices {
            let parentFd: Int32
            if i == 0 {
                parentFd = root.fd
            } else {
                parentFd = openat(root.fd, parts[..<i].joined(separator: "/"), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_RESOLVE_BENEATH)
                if parentFd < 0 { throw Self.fileError("mkdir", path, .current) }
            }
            let made = mkdirat(parentFd, parts[i], 0o777)
            let e = errno
            if i > 0 { Darwin.close(parentFd) }
            if made != 0 && e != EEXIST { throw Self.fileError("mkdir", path, OSFailure(e)) }
        }
        let dir = openat(root.fd, relative, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_RESOLVE_BENEATH)
        if dir < 0 { throw Self.fileError("open export directory", path, .current) }
        return ExportSequence(dir: dir)
    }

    /// Validates `path` for the write authority without touching the filesystem.
    func checkWrite(_ path: String) throws {
        _ = try Self.requestPath(path, write)
        guard write != nil else { throw AutomationError.absent("write") }
    }
}

/// An export that owns only files it created through its held directory capability: it refuses
/// collisions (including symbolic links), so a failed or cancelled export can never delete or
/// replace an earlier one (photocraft `ExportSequence`). Dropping it uncommitted removes what it
/// wrote.
public final class ExportSequence {
    let dir: Int32
    /// Files this sequence created, in order.
    public private(set) var created: [String] = []

    init(dir: Int32) { self.dir = dir }

    deinit {
        _ = try? cleanup()
        Darwin.close(dir)
    }

    /// Creates `name` (one plain component) with `bytes`; an existing entry is an error.
    public func write(_ name: String, _ bytes: Data) throws {
        _ = try AuthorizedWorkspace.relativePath(name)
        if name.contains("/") { throw AuthorizedWorkspace.pathError(name, "export filename must be a single component") }
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        if fd < 0 { throw AuthorizedWorkspace.fileError("create export", name, .current) }
        // Recorded right after creation, before any fallible write.
        created.append(name)
        defer { Darwin.close(fd) }
        if let e = AuthorizedWorkspace.writeAll(fd, bytes) ?? AuthorizedWorkspace.syncFile(fd) {
            throw AuthorizedWorkspace.fileError("write export", name, e)
        }
    }

    /// Keeps every file written so far.
    public func commit() { created.removeAll() }

    /// Removes every file this sequence created and has not committed.
    public func cleanup() throws {
        var failed: [String] = []
        created = created.filter { name in
            if unlinkat(dir, name, 0) == 0 { return false }
            let e = OSFailure.current
            if e.code == ENOENT { return false }
            failed.append("\(name): \(e)")
            return true
        }
        if !failed.isEmpty { throw AutomationError.io("export cleanup failed: \(failed.joined(separator: "; "))") }
    }
}

/// A `FileSystemService` confined to an automation workspace: what engine commands reach through
/// `Session.services.fileSystem` in an untrusted session.
public struct WorkspaceFileSystem: FileSystemService {
    public let workspace: AuthorizedWorkspace
    public init(_ w: AuthorizedWorkspace) { workspace = w }
    public func read(_ path: String) throws -> Data { try workspace.read(path) }
    public func write(_ path: String, _ data: Data) throws { try workspace.write(path, data) }
    public func exists(_ path: String) -> Bool { workspace.exists(path) }
}
