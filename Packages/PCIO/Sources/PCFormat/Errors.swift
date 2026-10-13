// Errors of the native format: photocraft's `FormatError` and the `std::io::Error` it wraps.
// Port of photocraft-format (crates/format/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import Foundation
import PCIOCore

/// A file-system failure with its kind (Rust's `std::io::ErrorKind`) and errno, so callers can
/// tell a full disk from a locked file.
public struct IOError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case notFound, permissionDenied, alreadyExists, storageFull, crossesDevices, readOnlyFilesystem
        case invalidInput, invalidData, outOfMemory, unsupported, isADirectory, notADirectory, other
    }

    public var kind: Kind
    /// The OS error number, when there is one.
    public var code: Int32?
    public var message: String

    public init(_ kind: Kind, _ message: String, code: Int32? = nil) {
        self.kind = kind
        self.message = message
        self.code = code
    }

    /// The error for `errno` value `code`, with `context` in front of the system's text.
    public init(errno code: Int32, _ context: String) {
        let text = String(cString: strerror(code))
        self.init(IOError.kind(errno: code), context.isEmpty ? text : "\(context): \(text) (os error \(code))", code: code)
    }

    /// The error for the current `errno`.
    static func last(_ context: String) -> IOError { IOError(errno: errno, context) }

    public static func kind(errno code: Int32) -> Kind {
        switch code {
        case ENOENT: .notFound
        case EACCES, EPERM: .permissionDenied
        case EEXIST: .alreadyExists
        case ENOSPC, EDQUOT: .storageFull
        case EXDEV: .crossesDevices
        case EROFS: .readOnlyFilesystem
        case EINVAL, ENAMETOOLONG: .invalidInput
        case ENOMEM: .outOfMemory
        case ENOTSUP, ENOTTY: .unsupported
        case EISDIR: .isADirectory
        case ENOTDIR: .notADirectory
        default: .other
        }
    }

    /// The same error with `context` in front of its message (kind and code kept).
    func context(_ context: String) -> IOError { IOError(kind, "\(context): \(message)", code: code) }

    public var description: String { message }
}

/// Everything that can go wrong reading or writing a `.pcraft` bundle (photocraft `FormatError`).
public enum FormatError: Error, Equatable, Sendable, CustomStringConvertible {
    case corrupt(String)
    case unsupported(String)
    /// The bundle was written by a newer version.
    case tooNew(found: UInt32, supported: UInt32)
    case limitExceeded(String)
    /// A float the manifest would have to hold is NaN or infinite (JSON can't spell those).
    case nonFinite(path: String)
    case io(IOError)
    case json(String)

    public var description: String {
        switch self {
        case .corrupt(let m): "corrupt .pcraft bundle: \(m)"
        case .unsupported(let m): "unsupported .pcraft feature: \(m)"
        case let .tooNew(found, supported): "bundle written by a newer version (format \(found), this build reads up to \(supported))"
        case .limitExceeded(let m): "limit exceeded: \(m)"
        case .nonFinite(let path): "`\(path)` is NaN or infinite, which a .pcraft manifest cannot hold; reset that value and save again"
        case .io(let e): "I/O: \(e)"
        case .json(let m): "manifest JSON: \(m)"
        }
    }

    /// The format's view of a container (ZIP) or codec error.
    static func from(_ e: PCIOError) -> FormatError {
        switch e {
        case .corrupt(let m): .corrupt(m)
        case .unsupported(let m): .unsupported(m)
        case .limitExceeded(let m): .limitExceeded(m)
        case .io(let m): .io(IOError(.other, m))
        default: .corrupt(e.description)
        }
    }

    /// Any error from a lower layer.
    static func wrap(_ e: Error) -> FormatError {
        switch e {
        case let f as FormatError: f
        case let p as PCIOError: .from(p)
        case let io as IOError: .io(io)
        case is DecodingError, is EncodingError: .json(jsonMessage(e))
        default: .io(IOError(.other, String(describing: e)))
        }
    }

    /// A readable message for a Codable error: what went wrong and where.
    static func jsonMessage(_ e: Error) -> String {
        func path(_ p: [any CodingKey]) -> String {
            var s = ""
            for k in p { s += k.intValue.map { "[\($0)]" } ?? ".\(k.stringValue)" }
            while s.hasPrefix(".") { s.removeFirst() }
            return s
        }
        switch e {
        case DecodingError.dataCorrupted(let c): return "\(c.debugDescription) at `\(path(c.codingPath))`"
        case DecodingError.keyNotFound(let k, let c): return "missing field `\(k.stringValue)` at `\(path(c.codingPath))`"
        case DecodingError.typeMismatch(let t, let c): return "expected \(t) at `\(path(c.codingPath))`: \(c.debugDescription)"
        case DecodingError.valueNotFound(let t, let c): return "expected \(t), got null at `\(path(c.codingPath))`"
        case EncodingError.invalidValue(_, let c): return "\(c.debugDescription) at `\(path(c.codingPath))`"
        default: return String(describing: e)
        }
    }
}
