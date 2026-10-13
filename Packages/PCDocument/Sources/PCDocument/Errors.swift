// The model's error type: invalid parameters and malformed data are reported, never trapped on
// (photocraft's "never crash" rule, AGENTS.md §3).
// Port support for photocraft-doc, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

/// A recoverable model error with a message a user or agent can act on.
public struct DocumentError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
