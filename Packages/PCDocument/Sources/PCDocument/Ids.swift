// Process-wide identities: layers, documents and smart-object contents share one counter, so an id
// is unique across all three kinds.
// Port of photocraft-doc (crates/doc/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import Synchronization

private let idCounter = Atomic<UInt64>(1)

/// The next id from the shared counter (wraps like photocraft's `fetch_add`, never traps).
func nextId() -> UInt64 { idCounter.wrappingAdd(1, ordering: .relaxed).oldValue }

/// Advance the process-wide id counter (shared by layer, document and smart-contents ids) past
/// `max`, so ids loaded from a file never collide with ids minted later. Never moves backwards.
public func ensureIdsAbove(_ max: UInt64) {
    let next = max == .max ? max : max + 1
    _ = idCounter.max(next, ordering: .relaxed)
}

/// A layer's identity, stable for its lifetime (duplicates get fresh ids). JSON: the bare number.
public struct LayerId: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public static func fresh() -> LayerId { LayerId(nextId()) }
    public static func < (a: LayerId, b: LayerId) -> Bool { a.rawValue < b.rawValue }
    public var description: String { "L\(rawValue)" }
}

/// Identity of the source contents shared by smart-object instances, independent of their bytes.
public struct SmartContentsId: RawRepresentable, Hashable, Comparable, Sendable, Codable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public static func fresh() -> SmartContentsId { SmartContentsId(nextId()) }
    public static func < (a: SmartContentsId, b: SmartContentsId) -> Bool { a.rawValue < b.rawValue }
}

/// A document's identity (colour state, views and caches are keyed by it).
public struct DocId: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public static func fresh() -> DocId { DocId(nextId()) }
}
