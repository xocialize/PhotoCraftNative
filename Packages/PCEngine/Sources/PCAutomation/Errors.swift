// Port of photocraft-automation (crates/automation/src/lib.rs `AutomationError`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft's automation error kinds, rendered the way its `Display` renders them, as the
// engine's one error type: the automation surface (control channel, MCP, CLI) reports
// `EngineError` everywhere, so callers match on one type and on photocraft's messages.

import Darwin
import PCEngine

/// photocraft `AutomationError`: each kind becomes an `EngineError` carrying photocraft's text.
public enum AutomationError {
    /// `BadRequest(msg)` → `msg`.
    public static func badRequest(_ message: String) -> EngineError { .other(message) }
    /// `Io(msg)` → `I/O: msg`.
    public static func io(_ message: String) -> EngineError { .other("I/O: \(message)") }
    /// `Bridge(msg)` → `bridge: msg`.
    public static func bridge(_ message: String) -> EngineError { .other("bridge: \(message)") }
    /// `App(msg)` → `app: msg`.
    public static func app(_ message: String) -> EngineError { .other("app: \(message)") }
    /// `Other(msg)` → `msg`.
    public static func other(_ message: String) -> EngineError { .other(message) }

    /// The fail-closed message prefix of every missing filesystem authority.
    public static let denied = "automation filesystem access is not granted"

    static func absent(_ authority: String) -> EngineError { badRequest("\(denied): \(authority) authority is absent") }
}

/// An operating-system error as Rust's `std::io::Error` shows it: its kind (`NotFound`, …) and
/// `"<strerror> (os error N)"`.
struct OSFailure: Error, CustomStringConvertible {
    let code: Int32

    init(_ code: Int32) { self.code = code }
    static var current: OSFailure { OSFailure(errno) }

    /// `std::io::ErrorKind`'s Debug name. `ENOTCAPABLE` (a resolve-beneath escape) is cap-std's
    /// "a path led outside of the filesystem", a `PermissionDenied`.
    var kind: String {
        switch code {
        case ENOENT: "NotFound"
        case EACCES, EPERM, ENOTCAPABLE: "PermissionDenied"
        case EEXIST: "AlreadyExists"
        case ENOTDIR: "NotADirectory"
        case EISDIR: "IsADirectory"
        case ENOTEMPTY: "DirectoryNotEmpty"
        case EROFS: "ReadOnlyFilesystem"
        case ELOOP: "FilesystemLoop"
        case ENOSPC: "StorageFull"
        case EXDEV: "CrossesDevices"
        case EBUSY: "ResourceBusy"
        case EINTR: "Interrupted"
        case EINVAL: "InvalidInput"
        case EAGAIN, ETIMEDOUT: code == ETIMEDOUT ? "TimedOut" : "WouldBlock"
        case ECONNREFUSED: "ConnectionRefused"
        case ECONNRESET: "ConnectionReset"
        case EPIPE: "BrokenPipe"
        case ENAMETOOLONG: "InvalidFilename"
        case EFBIG: "FileTooLarge"
        default: "Uncategorized"
        }
    }

    var description: String {
        if code == ENOTCAPABLE { return "a path led outside of the filesystem" }
        return "\(String(cString: strerror(code))) (os error \(code))"
    }
}
