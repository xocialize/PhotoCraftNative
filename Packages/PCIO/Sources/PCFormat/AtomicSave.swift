// Crash-safe file replacement: the one way PhotoCraft writes a document to disk.
//
// `atomicWrite` never truncates the destination. It writes a temporary file in the same
// directory, flushes it to stable storage (a full flush, `F_FULLFSYNC`), renames it over the
// destination and fsyncs the directory so the rename itself survives a power loss. If anything
// fails, the destination keeps its previous bytes and the temporary file is removed.
//
// - Locked files: a rename failing with "permission denied" can be retried with exponential
//   backoff (`RenameRetry`); the platform default retries only on Windows, so never here.
// - Cross-device (`EXDEV`): cannot happen while the temporary file sits beside the target; if it
//   does anyway, the save fails with a clear error. It never falls back to writing in place.
// - Unwritable folder: the save fails with a clear error instead of writing in place.
// - Network shares: `F_FULLFSYNC` is refused by SMB shares (`ENOTSUP`) and some virtual file
//   systems (`ENOTTY`); `syncFile` then falls back to a plain `fsync` (photocraft #1336).
//
// `atomicWriteWith` takes an `AtomicFS` so tests can inject failures at each step.
// Port of photocraft-format (crates/format/src/atomic.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import Foundation
import Synchronization

/// The file-system steps `atomicWriteWith` performs. `RealFS` is the real thing; tests wrap it to
/// inject failures.
public protocol AtomicFS {
    /// Creates `tmp` (it must not exist), writes all of `bytes` and flushes it (`syncFile`).
    func writeNew(_ tmp: String, _ bytes: [UInt8]) throws(IOError)
    /// `writeNew`, reporting the fraction of `bytes` written so far to `progress`.
    func writeNewProgress(_ tmp: String, _ bytes: [UInt8], _ progress: (Float) -> Void) throws(IOError)
    /// Renames `from` over `to`, replacing it.
    func rename(_ from: String, _ to: String) throws(IOError)
    /// Removes a (temporary) file.
    func remove(_ path: String) throws(IOError)
    /// Flushes a directory entry change.
    func syncDir(_ dir: String) throws(IOError)
    /// Copies the destination's permissions onto the temporary file (best effort).
    func copyPermissions(_ from: String, _ to: String) throws(IOError)
}

extension AtomicFS {
    public func writeNewProgress(_ tmp: String, _ bytes: [UInt8], _ progress: (Float) -> Void) throws(IOError) {
        try writeNew(tmp, bytes)
    }
}

/// The real file system.
public struct RealFS: AtomicFS {
    /// How much `writeNewProgress` writes between progress reports.
    public static let writeChunk = 8 << 20

    public init() {}

    public func writeNew(_ tmp: String, _ bytes: [UInt8]) throws(IOError) {
        try writeNewProgress(tmp, bytes) { _ in }
    }

    public func writeNewProgress(_ tmp: String, _ bytes: [UInt8], _ progress: (Float) -> Void) throws(IOError) {
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        if fd < 0 { throw IOError.last(tmp) }
        defer { close(fd) }
        var written = 0
        while written < bytes.count {
            let n = min(RealFS.writeChunk, bytes.count - written)
            try AtomicSave.writeAll(fd, bytes, written, n, tmp)
            written += n
            progress(Float(written) / Float(max(bytes.count, 1)))
        }
        try AtomicSave.syncFile(fd)
    }

    public func rename(_ from: String, _ to: String) throws(IOError) {
        if Darwin.rename(from, to) != 0 { throw IOError.last("rename") }
    }

    public func remove(_ path: String) throws(IOError) {
        if unlink(path) != 0 { throw IOError.last(path) }
    }

    public func syncDir(_ dir: String) throws(IOError) {
        let fd = open(dir, O_RDONLY | O_CLOEXEC)
        if fd < 0 { throw IOError.last(dir) }
        defer { close(fd) }
        try AtomicSave.syncFile(fd)
    }

    public func copyPermissions(_ from: String, _ to: String) throws(IOError) {
        var st = stat()
        if stat(from, &st) != 0 { throw IOError.last(from) }
        if chmod(to, st.st_mode & 0o7777) != 0 { throw IOError.last(to) }
    }
}

/// How hard to retry a rename that fails with "permission denied".
public struct RenameRetry: Sendable {
    /// Retries after the first attempt (0 = no retry).
    public var attempts: UInt32
    /// Delay before the first retry; doubles each time.
    public var firstDelayMs: UInt64

    public init(attempts: UInt32, firstDelayMs: UInt64) { self.attempts = attempts; self.firstDelayMs = firstDelayMs }

    /// The platform default: photocraft retries on Windows (antivirus and indexers hold files
    /// open) and never elsewhere, where "permission denied" is a real problem that waiting won't fix.
    public static var platform: RenameRetry { RenameRetry(attempts: 0, firstDelayMs: 0) }
}

public enum AtomicSave {
    /// Atomically replaces (or creates) the file at `url` with `bytes`. Errors keep their kind and
    /// say what happened and that the original file is unchanged.
    public static func atomicWrite(_ url: URL, _ bytes: [UInt8]) throws(IOError) {
        try atomicWriteWith(RealFS(), .platform, url.path, bytes)
    }

    /// `atomicWrite` reporting the fraction of `bytes` written to `progress` as it goes; the flush
    /// and rename follow the last report.
    public static func atomicWriteProgress(_ url: URL, _ bytes: [UInt8], _ progress: (Float) -> Void) throws(IOError) {
        try atomicWriteWithProgress(RealFS(), .platform, url.path, bytes, progress)
    }

    /// `atomicWrite` through an explicit file system and retry policy (the failure-injection seam).
    public static func atomicWriteWith(_ fs: some AtomicFS, _ retry: RenameRetry, _ path: String, _ bytes: [UInt8]) throws(IOError) {
        try atomicWriteWithProgress(fs, retry, path, bytes) { _ in }
    }

    public static func atomicWriteWithProgress(_ fs: some AtomicFS, _ retry: RenameRetry, _ path: String, _ bytes: [UInt8],
                                               _ progress: (Float) -> Void) throws(IOError) {
        let target = resolveSymlink(path)
        let ns = target as NSString
        let name = ns.lastPathComponent
        guard !target.isEmpty, !name.isEmpty, name != "/", !target.hasSuffix("/") else {
            throw IOError(.invalidInput, "\(path): not a file path")
        }
        var dir = ns.deletingLastPathComponent
        if dir.isEmpty { dir = "." }
        try FS.createDirAll(dir)

        // A fresh temporary file next to the target (same directory, so the rename never crosses a
        // device). The name is unique per process and call; retry a few on collisions.
        var tmp: String?
        for _ in 0 ..< 8 {
            let candidate = (dir as NSString).appendingPathComponent(tempName(name))
            do throws(IOError) {
                try fs.writeNewProgress(candidate, bytes, progress)
                tmp = candidate
                break
            } catch {
                if error.kind == .alreadyExists { continue }
                // A partial temp file may exist; the destination was never touched.
                try? fs.remove(candidate)
                throw writeError(error, path, dir)
            }
        }
        guard let tmp else { throw IOError(.alreadyExists, "\(dir): could not create a temporary file") }

        // Keep the existing file's mode (e.g. 0600) instead of the process default.
        if FileManager.default.fileExists(atPath: target) { try? fs.copyPermissions(target, tmp) }

        do throws(IOError) {
            try retryRename(retry) { () throws(IOError) in try fs.rename(tmp, target) }
        } catch {
            try? fs.remove(tmp)
            throw renameError(error, path)
        }
        // The new bytes are in place; a failed directory fsync can't be undone and must not report
        // the save as failed, so it is best effort.
        try? fs.syncDir(dir)
    }

    /// Runs `rename`, retrying with backoff while it fails with "permission denied".
    public static func retryRename(_ retry: RenameRetry, _ rename: () throws(IOError) -> Void) throws(IOError) {
        var delay = retry.firstDelayMs
        var left = retry.attempts
        while true {
            do throws(IOError) {
                try rename()
                return
            } catch {
                guard error.kind == .permissionDenied, left > 0 else { throw error }
                left -= 1
                usleep(UInt32(min(delay * 1000, UInt64(UInt32.max))))
                delay = delay.multipliedReportingOverflow(by: 2).overflow ? .max : delay * 2
            }
        }
    }

    /// Writes through a symlink to the file it points at, instead of replacing the link.
    static func resolveSymlink(_ path: String) -> String {
        var st = stat()
        if lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFLNK, let real = realpath(path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        return path
    }

    private static let counter = Atomic<UInt64>(0)

    /// A unique hidden temporary file name to write beside `file` before renaming over it:
    /// `.{stem}.{pid}-{n}.pcsave.tmp`.
    public static func tempName(_ file: String) -> String {
        let n = counter.wrappingAdd(1, ordering: .relaxed).oldValue
        // Keep the name short: a long file name plus the suffix must stay under NAME_MAX.
        let stem = String(file.prefix(64))
        return ".\(stem).\(getpid())-\(n).pcsave.tmp"
    }

    static let unchanged = "the original file was not changed"

    static func writeError(_ e: IOError, _ path: String, _ dir: String) -> IOError {
        let msg: String
        switch e.kind {
        case .permissionDenied, .readOnlyFilesystem:
            msg = "cannot save \(path): the folder \(dir) is not writable (\(e)); \(unchanged)"
        case .storageFull:
            msg = "cannot save \(path): the disk is full (\(e)); \(unchanged)"
        default:
            msg = "cannot save \(path): \(e); \(unchanged)"
        }
        return IOError(e.kind, msg, code: e.code)
    }

    static func renameError(_ e: IOError, _ path: String) -> IOError {
        let msg: String
        if e.kind == .crossesDevices || e.code == EXDEV {
            msg = "cannot save \(path): the temporary file is on a different volume than the destination (\(e)); \(unchanged)"
        } else if e.kind == .permissionDenied {
            msg = "cannot save \(path): the file is locked or read-only (\(e)); \(unchanged)"
        } else {
            msg = "cannot save \(path): \(e); \(unchanged)"
        }
        return IOError(e.kind, msg, code: e.code)
    }

    // MARK: Flushing

    /// Flushes `fd` to stable storage with a full flush (`F_FULLFSYNC`); where the file system
    /// can't do one (SMB shares refuse it with `ENOTSUP`, some virtual file systems with `ENOTTY`)
    /// this falls back to a plain `fsync`, as Apple's own `removefile` does. Any other error is
    /// returned as it is.
    public static func syncFile(_ fd: Int32) throws(IOError) {
        let full: Result<Void, IOError> = fcntl(fd, F_FULLFSYNC) == -1 ? .failure(IOError.last("F_FULLFSYNC")) : .success(())
        try orPlainFsync(full) { () throws(IOError) in
            if fsync(fd) != 0 { throw IOError.last("fsync") }
        }
    }

    /// `full`, or `fsync()` when `full` failed only because the file system can't do a full flush.
    public static func orPlainFsync(_ full: Result<Void, IOError>, _ fsync: () throws(IOError) -> Void) throws(IOError) {
        switch full {
        case .success: return
        case .failure(let e):
            if fullFlushUnsupported(e) { try fsync() } else { throw e }
        }
    }

    /// Whether `e` is a file system refusing a full flush: `ENOTSUP` (45, SMB) or `ENOTTY` (25).
    static func fullFlushUnsupported(_ e: IOError) -> Bool { e.code == ENOTSUP || e.code == ENOTTY }

    /// Writes `n` bytes of `bytes` from `offset`, retrying short writes and `EINTR`.
    static func writeAll(_ fd: Int32, _ bytes: [UInt8], _ offset: Int, _ n: Int, _ what: String) throws(IOError) {
        var done = 0
        while done < n {
            let w = bytes.withUnsafeBytes { p in Darwin.write(fd, p.baseAddress.map { $0 + offset + done }, n - done) }
            if w < 0 {
                if errno == EINTR { continue }
                throw IOError.last(what)
            }
            done += w
        }
    }
}
