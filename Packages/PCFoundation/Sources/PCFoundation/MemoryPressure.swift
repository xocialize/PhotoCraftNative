// New (no photocraft counterpart): the system's memory-pressure events, relayed to the caches that
// can shrink. PhotoCraftNative's CPU caches (CPUCompositor's effect maps, DocumentLeafCache, the
// smart-object stage cache) and PCAlgo's reusable textures are not part of a GPU tenant declaration
// (AB-A-0169 §2), but they count in the process's physical footprint; this trims them when macOS
// says memory is short.
//
// Caches register a trim closure (each module registers its own; PCFoundation knows none of them).
// Nothing listens until a host calls `start()`, so behaviour is unchanged until it opts in.

import Dispatch
import Foundation
import Synchronization

public final class MemoryPressureRelay: Sendable {
    /// How short memory is: a warning trims caches to half, critical empties them.
    public enum Level: Int, Sendable, Comparable, CustomStringConvertible {
        case warning = 1, critical = 2
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        public var description: String { self == .warning ? "warning" : "critical" }
    }

    /// One cache's answer to a relayed event.
    public struct Trim: Sendable, Equatable {
        public let name: String
        public let freed: Int
        public init(name: String, freed: Int) { self.name = name; self.freed = freed }
    }

    /// The process-wide relay.
    public static let shared = MemoryPressureRelay()

    private struct State {
        var next: UInt64 = 0
        var trims: [UInt64: (name: String, trim: @Sendable (Level) -> Int)] = [:]
        var source: (any DispatchSourceMemoryPressure)?
        var observer: (@Sendable (Level, [Trim]) -> Void)?
    }
    private let state = Mutex(State())

    public init() {}

    /// Registers `trim` (returns the bytes it freed) until the registration is released.
    public func register(_ name: String, trim: @escaping @Sendable (Level) -> Int) -> MemoryPressureRegistration {
        let id = state.withLock { s in
            s.next += 1
            s.trims[s.next] = (name, trim)
            return s.next
        }
        return MemoryPressureRegistration(relay: self, id: id)
    }

    func unregister(_ id: UInt64) { _ = state.withLock { $0.trims.removeValue(forKey: id) } }

    /// Names of the registered caches.
    public var registered: [String] { state.withLock { $0.trims.sorted { $0.key < $1.key }.map(\.value.name) } }

    /// Listens for the system's warning and critical events on `queue` (idempotent).
    public func start(queue: DispatchQueue = DispatchQueue(label: "PhotoCraftNative.memory-pressure", qos: .utility)) {
        let source: (any DispatchSourceMemoryPressure)? = state.withLock { s in
            guard s.source == nil else { return nil }
            let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
            s.source = src
            return src
        }
        guard let source else { return }
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            if event.contains(.critical) { self.relay(.critical) } else if event.contains(.warning) { self.relay(.warning) }
        }
        source.activate()
    }

    /// Stops listening.
    public func stop() {
        let source = state.withLock { s in
            defer { s.source = nil }
            return s.source
        }
        source?.cancel()
    }

    public var isListening: Bool { state.withLock { $0.source != nil } }

    /// Called after each relayed event with what every cache freed (a host logs it).
    public var onRelay: (@Sendable (Level, [Trim]) -> Void)? {
        get { state.withLock { $0.observer } }
        set { state.withLock { $0.observer = newValue } }
    }

    /// Runs every registered trim for `level` now (the source calls this; so can drills and tests).
    @discardableResult
    public func relay(_ level: Level) -> [Trim] {
        let (trims, observer) = state.withLock { s in (s.trims.sorted { $0.key < $1.key }.map(\.value), s.observer) }
        let out = trims.map { Trim(name: $0.name, freed: $0.trim(level)) }
        observer?(level, out)
        return out
    }
}

/// Keeps a cache registered with a `MemoryPressureRelay`; releasing it unregisters.
public final class MemoryPressureRegistration: Sendable {
    let relay: MemoryPressureRelay
    let id: UInt64
    init(relay: MemoryPressureRelay, id: UInt64) { self.relay = relay; self.id = id }
    deinit { relay.unregister(id) }
}
