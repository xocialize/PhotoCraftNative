// Port of photocraft-engine (crates/engine/src/lib.rs `EngineError`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The engine's one error type. Every command failure is one of these; nothing traps (photocraft's
// "never crash" rule). The messages are photocraft's, so scripts and agents that match on them
// keep working.

import PCDocument

public enum EngineError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No command with this id is registered.
    case unknownCommand(String)
    /// The command's precondition fails (`enabled` returned the reason).
    case disabled(String, String)
    /// The parameters don't fit the command.
    case badParams(cmd: String, msg: String)
    /// The command needs a document and none is open.
    case noDocument
    /// The command names a layer that isn't in the document.
    case noLayer(LayerId)
    /// Anything else, with a message a user or agent can act on.
    case other(String)
    /// A background job was cancelled; nothing changed.
    case cancelled
    /// The command is registered but can't run in this build yet (its implementation waits on a
    /// package that isn't finished, or on a platform service): the reason says which.
    case unavailable(String, String)

    public var description: String {
        switch self {
        case .unknownCommand(let id): "unknown command `\(id)`"
        case .disabled(let id, let why): "command `\(id)` is not available right now: \(why)"
        case .badParams(let cmd, let msg): "invalid parameters for `\(cmd)`: \(msg)"
        case .noDocument: "no active document"
        case .noLayer(let id): "no such layer LayerId(\(id.rawValue))"
        case .other(let m): m
        case .cancelled: "cancelled"
        case .unavailable(let id, let why): "command `\(id)` is unavailable in this build: \(why)"
        }
    }

    /// `badParams` shorthand (photocraft `bad`).
    public static func bad(_ cmd: String, _ msg: String) -> EngineError { .badParams(cmd: cmd, msg: msg) }

    /// A model error as an engine error.
    public init(_ e: DocumentError) { self = .other(e.message) }

    /// Any error as an engine error (engine errors pass through; others keep their message).
    public static func wrap(_ e: any Error) -> EngineError {
        if let e = e as? EngineError { return e }
        if let e = e as? DocumentError { return .other(e.message) }
        if e is CancellationError { return .cancelled }
        return .other(String(describing: e))
    }
}

/// photocraft's `Result<(), String>` precondition: nil when the command can run, else why not.
public typealias Precondition = String?
