// Port of photocraft architecture §4.1 (`Session::events`: DocChanged{damage}, JobProgress, Toast, …) and photocraft-engine's revision/damage bookkeeping (crates/engine/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Commands in, events out. Every subscriber gets its own `AsyncStream`; the hub is Sendable, so a
// job's worker thread reports progress straight to the UI without touching the session.

import Foundation
import PCDocument
import PCFoundation
import Synchronization

/// Something the session did that a frontend may want to redraw or report.
public enum SessionEvent: Sendable, Equatable {
    /// A document changed: its new revision and the area to recomposite (nil = everything).
    case documentChanged(DocId, revision: UInt64, damage: PixelRect?)
    /// A document was opened or created at `index`.
    case documentOpened(DocId, index: Int)
    case documentClosed(DocId)
    /// The active document changed (nil = none open).
    case activeDocumentChanged(DocId?)
    /// The targeted layers changed without an edit (selecting layers is not a step).
    case layerTargetChanged(DocId)
    /// A command finished (`journal` false for queries).
    case commandFinished(id: String, journal: Bool)
    /// Tool state (colours, brush) changed.
    case toolsChanged
    /// Preferences changed.
    case preferencesChanged
    /// A background job started.
    case jobStarted(JobId, command: String, label: String)
    /// A job reported progress (0…1) with a status message.
    case jobProgress(JobId, fraction: Float, message: String)
    /// A job's work finished on its worker: call `Session.pollJobs()` to apply it.
    case jobReady(JobId)
    /// A job ended (applied, failed or cancelled).
    case jobEnded(JobId, JobOutcome)
    /// A message for the status bar.
    case toast(String)
}

/// Broadcasts session events to every subscriber.
public final class EventHub: Sendable {
    private let subscribers = Mutex<[UInt64: AsyncStream<SessionEvent>.Continuation]>([:])
    private let next = Atomic<UInt64>(0)

    public init() {}

    /// A new stream of every event from now on. Ends when the subscriber stops iterating.
    public func stream(bufferingNewest limit: Int = 1024) -> AsyncStream<SessionEvent> {
        let id = next.add(1, ordering: .relaxed).newValue
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(limit))
        continuation.onTermination = { [weak self] _ in
            _ = self?.subscribers.withLock { $0.removeValue(forKey: id) }
        }
        subscribers.withLock { $0[id] = continuation }
        return stream
    }

    public func emit(_ e: SessionEvent) {
        let conts = subscribers.withLock { Array($0.values) }
        for c in conts { c.yield(e) }
    }

    public var subscriberCount: Int { subscribers.withLock { $0.count } }

    /// Ends every stream (the session is going away).
    public func finish() {
        let conts = subscribers.withLock { s -> [AsyncStream<SessionEvent>.Continuation] in
            defer { s.removeAll() }
            return Array(s.values)
        }
        for c in conts { c.finish() }
    }
}

/// A read-only view of one document for another thread: a value copy (copy-on-write, so O(1)),
/// published after every change (architecture §6 "snapshots for readers").
public struct DocSnapshot: Sendable {
    public var state: DocState
    public var index: Int
    public var doc: Document { state.doc }
    public var revision: UInt64 { state.revision }
    public var activeLayer: LayerId? { state.activeLayer }
    public var selectedLayers: [LayerId] { state.selectedLayers }
    public var damage: PixelRect? { state.lastDamage }
}

/// The latest snapshot of every open document, readable from any thread (renderers, autosave,
/// background jobs). A read is a lock-protected value copy, never a wait on the session.
public final class SnapshotStore: Sendable {
    private let docs = Mutex<[DocSnapshot]>([])
    private let activeId = Mutex<DocId?>(nil)

    public init() {}

    func publish(_ states: [DocState], active: Int?) {
        let snaps = states.enumerated().map { DocSnapshot(state: $1, index: $0) }
        docs.withLock { $0 = snaps }
        activeId.withLock { $0 = active.flatMap { $0 < states.count ? states[$0].id : nil } }
    }

    /// Every open document's snapshot, in tab order.
    public var all: [DocSnapshot] { docs.withLock { $0 } }

    public func snapshot(_ id: DocId) -> DocSnapshot? { docs.withLock { $0.first { $0.state.id == id } } }

    /// The active document's snapshot.
    public var active: DocSnapshot? {
        let id = activeId.withLock { $0 }
        return id.flatMap(snapshot)
    }
}
