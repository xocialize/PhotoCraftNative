// Undo/redo history with per-state targeted layers, a memory cap with oldest-first eviction and
// named snapshots.
// Port of photocraft-ops (crates/ops/src/lib.rs; snapshots from photocraft-engine
// history_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Because pixel tiles are copy-on-write (see PCFoundation's `Surface`), a `Document` copy costs
// O(1) up front and shares every tile; edits copy only the tiles they touch. History therefore
// stores whole-document snapshots per step, which is simple, obviously correct, and the same
// approach Photoshop's History panel exposes to users (one state per step). Steps may also be
// expressed as reversible operations (`EditTransaction`, Ops.swift) and committed here.
//
// Memory is bounded by `maxStates` plus an approximate byte budget. The current document's tiles
// and the tiles only history holds count against it, including selection masks.

import Foundation
import PCDocument
import PCFoundation

/// The layers a state targeted: the active ("key") layer and every selected layer. Undo and redo
/// bring them back with the state's document, as the reference app does. Selecting layers is not a
/// step of its own, so the session updates the current state's target with `setCurrentLayers`
/// just before recording the next step.
public struct LayerTarget: Hashable, Sendable {
    public var active: LayerId?
    public var selected: [LayerId]

    public init(active: LayerId? = nil, selected: [LayerId] = []) { self.active = active; self.selected = selected }

    /// One layer, active and selected.
    public static func single(_ id: LayerId) -> LayerTarget { LayerTarget(active: id, selected: [id]) }
}

/// One past (or redoable) state.
public struct HistoryState: Sendable {
    public var label: String
    public var doc: Document
    /// The layers targeted when this state was created.
    public var layers: LayerTarget

    public init(label: String, doc: Document, layers: LayerTarget) { self.label = label; self.doc = doc; self.layers = layers }
}

/// A History panel snapshot (the camera button): a named copy of the document that outlives the
/// states, for the session only, as in Photoshop. Its tiles are shared copy-on-write with the
/// document and its history and are not counted in the history's pixel budget.
public struct HistorySnapshot: Sendable {
    /// Never reused within a history.
    public var id: UInt64
    public var name: String
    public var doc: Document
    public var layers: LayerTarget
}

/// The undo/redo history of one document.
public struct History: Sendable {
    /// Past states; the last one is the state *before* the current document.
    var undoStack: [HistoryState] = []
    var redoStack: [HistoryState] = []
    /// Lazily initialised when a byte budget is used; unlimited histories pay no counting cost.
    var ledger: TileLedger?
    /// Most past states kept (at least 1 when set through `init`).
    public var maxStates: Int
    /// Pixel memory budget in bytes for the current document plus the tiles only history holds
    /// (0 = unlimited). `trim` drops the oldest states beyond it.
    public var maxBytes: Int = 0
    /// Label of the step that produced the current document.
    private var currentLabel: String = "Open"
    /// The layers targeted when the current document was created (opened or edited).
    private var currentLayers = LayerTarget()
    /// Named snapshots, oldest first.
    public private(set) var snapshots: [HistorySnapshot] = []
    private var nextSnapshotId: UInt64 = 1

    public init(maxStates: Int = 50) {
        self.maxStates = max(maxStates, 1)
    }

    /// Record that `before` was replaced by a new current document via step `label`, which left
    /// `layers` targeted.
    public mutating func record(_ label: String, before: Document, layers: LayerTarget) {
        if maxBytes == 0 { ledger = nil }
        ledger?.add(before)
        let prevLabel = currentLabel
        let prevLayers = currentLayers
        currentLabel = label
        currentLayers = layers
        undoStack.append(HistoryState(label: prevLabel, doc: before, layers: prevLayers))
        clearRedo()
        while undoStack.count > maxStates {
            let state = undoStack.removeFirst()
            ledger?.remove(state.doc)
        }
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    /// The step undo would revert (the current state's label).
    public var undoLabel: String? { canUndo ? currentLabel : nil }
    public var redoLabel: String? { redoStack.last?.label }
    /// Labels of the redo states, the next redo first (the History panel's greyed rows).
    public var redoLabels: [String] { redoStack.reversed().map(\.label) }

    /// Set the layers the current document targets from its creation on: when it is first opened,
    /// or when its step coalesces or changes the selection after recording.
    public mutating func setCurrentLayers(_ layers: LayerTarget) { currentLayers = layers }

    /// The layers the current document targets.
    public var currentTarget: LayerTarget { currentLayers }

    /// Undo: `current` becomes redoable; returns the document to make current and the layers it
    /// targeted when it was created.
    public mutating func undo(_ current: Document) -> (doc: Document, layers: LayerTarget)? {
        guard let prev = undoStack.popLast() else { return nil }
        ledger?.remove(prev.doc)
        ledger?.add(current)
        let label = currentLabel
        let layers = currentLayers
        currentLabel = prev.label
        currentLayers = prev.layers
        redoStack.append(HistoryState(label: label, doc: current, layers: layers))
        return (prev.doc, prev.layers)
    }

    /// Redo: the mirror of `undo`.
    public mutating func redo(_ current: Document) -> (doc: Document, layers: LayerTarget)? {
        guard let next = redoStack.popLast() else { return nil }
        ledger?.remove(next.doc)
        ledger?.add(current)
        let label = currentLabel
        let layers = currentLayers
        currentLabel = next.label
        currentLayers = next.layers
        undoStack.append(HistoryState(label: label, doc: current, layers: layers))
        return (next.doc, next.layers)
    }

    /// Entries for a History panel: past labels oldest → newest, then the current label.
    public var entries: [String] { undoStack.map(\.label) + [currentLabel] }

    /// Document of past entry `i`, indexed like `entries` (0 = oldest). The last entry is the
    /// current document, which the history does not hold, so it (and any index past it) is nil.
    public func state(_ i: Int) -> Document? { i >= 0 && i < undoStack.count ? undoStack[i].doc : nil }

    /// Past state `i` with its label and targeted layers.
    public func pastState(_ i: Int) -> HistoryState? { i >= 0 && i < undoStack.count ? undoStack[i] : nil }

    /// Number of past states (entries before the current one).
    public var pastCount: Int { undoStack.count }

    /// Rename the current step (e.g. after folding several steps into one with `purgeLast`).
    public mutating func setCurrentLabel(_ label: String) { currentLabel = label }

    /// The current step's label.
    public var label: String { currentLabel }

    /// Forget the most recent undo state and every redo state (Edit › Purge › Undo): the last step
    /// can no longer be undone and its pixels are released.
    @discardableResult
    public mutating func purgeLast() -> Bool {
        clearRedo()
        guard let state = undoStack.popLast() else { return false }
        ledger?.remove(state.doc)
        return true
    }

    /// Forget the redo states, e.g. after undoing half of a compound step that failed.
    public mutating func clearRedo() {
        if ledger != nil { for s in redoStack { ledger?.remove(s.doc) } }
        redoStack.removeAll()
    }

    /// Forget every past and redo state (snapshots stay).
    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        ledger = nil
    }

    /// Approximate unique pixel bytes held by history (tiles not shared with `current`).
    public func uniqueBytes(_ current: Document) -> Int {
        var seen = Set<UInt64>()
        _ = tileBytes(current, &seen)
        return (undoStack + redoStack).reduce(0) { $0.addingSaturating(tileBytes($1.doc, &seen)) }
    }

    /// Pixel bytes of `current` plus the tiles only history holds (what `trim` bounds by
    /// `maxBytes`).
    public func pixelBytes(_ current: Document) -> Int {
        if let ledger { return ledger.bytesWith(current) }
        var seen = Set<UInt64>()
        let own = tileBytes(current, &seen)
        return (undoStack + redoStack).reduce(own) { $0.addingSaturating(tileBytes($1.doc, &seen)) }
    }

    /// Keep pixel memory within `maxBytes`: the current document's tiles plus the tiles only
    /// history holds (newest states first). The oldest undo states that don't fit are dropped; the
    /// most recent one is always kept so the last step can be undone. Returns how many states were
    /// dropped.
    @discardableResult
    public mutating func trim(_ current: Document) -> Int {
        if maxBytes == 0 || undoStack.count <= 1 { return 0 }
        if ledger == nil {
            var l = TileLedger()
            for s in undoStack { l.add(s.doc) }
            for s in redoStack { l.add(s.doc) }
            ledger = l
        }
        guard var ledger else { return 0 }
        if ledger.fits(current, budget: maxBytes) { return 0 }
        var seen = Set<UInt64>()
        var total = tileBytes(current, &seen)
        for s in redoStack.reversed() { total = total.addingSaturating(tileBytes(s.doc, &seen)) }
        var keep = 0
        for s in undoStack.reversed() {
            total = total.addingSaturating(tileBytes(s.doc, &seen))
            if total > maxBytes && keep >= 1 { break }
            keep += 1
        }
        let drop = undoStack.count - keep
        for s in undoStack.prefix(drop) { ledger.remove(s.doc) }
        undoStack.removeFirst(drop)
        self.ledger = ledger
        return drop
    }

    // MARK: Snapshots

    /// Takes a named snapshot (History › New Snapshot): `name` defaults to "Snapshot N".
    @discardableResult
    public mutating func takeSnapshot(name: String? = nil, doc: Document, layers: LayerTarget) -> HistorySnapshot {
        let id = nextSnapshotId
        nextSnapshotId = id == .max ? id : id + 1
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let snap = HistorySnapshot(id: id, name: trimmed.isEmpty ? "Snapshot \(id)" : trimmed, doc: doc, layers: layers)
        snapshots.append(snap)
        return snap
    }

    public func snapshot(_ id: UInt64) -> HistorySnapshot? { snapshots.first { $0.id == id } }

    /// Renames a snapshot; false when there is no such snapshot or the name is blank.
    @discardableResult
    public mutating func renameSnapshot(_ id: UInt64, to name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = snapshots.firstIndex(where: { $0.id == id }) else { return false }
        snapshots[i].name = n
        return true
    }

    /// Deletes a snapshot; the document and its history are unchanged.
    @discardableResult
    public mutating func deleteSnapshot(_ id: UInt64) -> HistorySnapshot? {
        guard let i = snapshots.firstIndex(where: { $0.id == id }) else { return nil }
        return snapshots.remove(at: i)
    }

    /// Clicking a snapshot: the document returns to it as one new, undoable state named after it.
    /// The current document's identity and name are kept (colour state, views and caches are keyed
    /// by them). Returns the document to make current and the layers to target (the snapshot's
    /// active layer when it still exists, else the top layer).
    public mutating func restoreSnapshot(_ id: UInt64, current: Document) -> (doc: Document, layers: LayerTarget)? {
        guard let snap = snapshot(id) else { return nil }
        var doc = snap.doc
        doc.id = current.id
        doc.name = current.name
        let active = snap.layers.active.flatMap { doc.contains($0) ? $0 : nil } ?? doc.topLayer
        let layers = active == snap.layers.active ? snap.layers : LayerTarget(active: active, selected: active.map { [$0] } ?? [])
        record(snap.name, before: current, layers: layers)
        return (doc, layers)
    }
}
