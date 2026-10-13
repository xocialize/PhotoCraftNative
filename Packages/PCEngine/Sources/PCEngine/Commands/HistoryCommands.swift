// Port of photocraft-engine (crates/engine/src/history_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// History panel actions beyond stepping: Delete (the trash button) and New Document (the "Create
// new document from current state" button), plus `history.undo` / `history.redo` aliases of
// Edit › Undo / Redo. States are indexed like `History.entries`: 0 is the oldest state still held,
// the last index is the current document.
//
// Snapshots (the camera button) are named copies of the document that outlive the states:
// `history.newSnapshot` takes one, `history.selectSnapshot` brings it back as a new, undoable
// state. They live in the document's `History` (PCHistory's snapshot store) for the session only,
// as in Photoshop, and are addressed by an id that is never reused.

import Foundation
import PCDocument
import PCFoundation
import PCHistory

enum HistoryCommands: CommandModule {
    static let name = "history_cmds"
    static let m = name

    /// The `state` param as an index into the active document's history entries, defaulting to
    /// the current state. Returns `(index, current)`.
    static func stateIndex(_ s: Session, _ cmd: String, _ p: JSONValue) throws -> (Int, Int) {
        guard let st = s.active else { throw EngineError.noDocument }
        let current = st.history.pastCount
        switch p["state"] {
        case nil, .null?:
            return (current, current)
        case _?:
            guard let v = Params.int(p, "state") else { throw EngineError.bad(cmd, "`state` must be a number") }
            guard v >= 0, v <= current else { throw EngineError.bad(cmd, "`state` = \(v) is not a state (0..=\(current))") }
            return (v, current)
        }
    }

    /// History panel › Delete: drop the state and every state after it, as Photoshop does in linear
    /// history. The document returns to the state before it, and the deleted steps can't be redone.
    /// The oldest state (the document as opened) can't be deleted.
    static func deleteState(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "history.deleteState"
        let (i, current) = try stateIndex(s, cmd, p)
        if i == 0 { throw EngineError.bad(cmd, "the oldest state can't be deleted") }
        // Step back to the state before `i`; the steps from `i` on are then redo states.
        for _ in i...current {
            if !s.undo() { throw EngineError.other("the history can't step back right now") }
        }
        let entries = try s.updateActive { st -> [String] in
            st.history.clearRedo()
            return st.history.entries
        }
        return ["states": .int(entries.count), "current": entries.last.map(JSONValue.string) ?? .null]
    }

    /// History panel › New Document: a new untitled document holding the document as it was at a
    /// state (the current one by default), named after that state, with a history of its own.
    static func newDocument(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "history.newDocument"
        let (i, current) = try stateIndex(s, cmd, p)
        guard let st = s.active else { throw EngineError.noDocument }
        guard var doc = i == current ? st.doc : st.history.state(i) else { throw EngineError.bad(cmd, "state \(i) is not held") }
        let entries = st.history.entries
        let label = i < entries.count ? entries[i] : ""
        doc.id = .fresh()
        if let n = p["name"]?.stringValue, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.name = n
        } else if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.name = label
        } else {
            doc.name = "\(doc.name) copy"
        }
        doc.reassignLayerIds()
        let name = doc.name
        let index = s.addDocument(doc)
        return ["document": .int(index), "name": .string(name)]
    }

    /// The `snapshot` param: the id of one of the active document's snapshots.
    static func snapshotId(_ s: Session, _ cmd: String, _ p: JSONValue) throws -> UInt64 {
        guard let st = s.active else { throw EngineError.noDocument }
        guard let id = p["snapshot"]?.uint64Value else { throw EngineError.bad(cmd, "`snapshot` must be a snapshot id") }
        guard st.history.snapshot(id) != nil else { throw EngineError.bad(cmd, "no snapshot \(id)") }
        return id
    }

    /// A non-blank `name` param, trimmed; nil when absent.
    static func nameParam(_ cmd: String, _ p: JSONValue) throws -> String? {
        switch p["name"] {
        case nil, .null?: return nil
        case .string(let n)? where !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return n.trimmingCharacters(in: .whitespacesAndNewlines)
        default: throw EngineError.bad(cmd, "`name` must be a non-empty string")
        }
    }

    /// History panel › Create new snapshot (the camera button): a named copy of the document,
    /// "Snapshot N" by default. `from` is the New Snapshot dialog's From: the full document
    /// (default), its layers merged into one, or only the active layer. Not a history state.
    static func newSnapshot(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "history.newSnapshot"
        let name = try nameParam(cmd, p)
        let from: String
        switch p["from"] {
        case nil, .null?: from = "fullDocument"
        case .string(let f)? where ["fullDocument", "mergedLayers", "currentLayer"].contains(f): from = f
        default: throw EngineError.bad(cmd, "`from` must be \"fullDocument\", \"mergedLayers\" or \"currentLayer\"")
        }
        guard let st = s.active else { throw EngineError.noDocument }
        func oneLayer(_ layer: Layer) -> (Document, LayerTarget) {
            var doc = st.doc
            doc.layers = [layer]
            return (doc, LayerTarget.single(layer.id))
        }
        let doc: Document, layers: LayerTarget
        switch from {
        case "mergedLayers":
            let merged = try s.services.renderer.compositeToSurface(st.doc, format: st.doc.pixelFormat)
            (doc, layers) = oneLayer(Layer(name: "Merged Layers", content: .raster(merged)))
        case "currentLayer":
            guard let id = st.activeLayer, let l = st.doc.layer(id) else { throw EngineError.bad(cmd, "no active layer") }
            (doc, layers) = oneLayer(l)
        default:
            (doc, layers) = (st.doc, st.layerTarget)
        }
        let snap = try s.updateActive { st in st.history.takeSnapshot(name: name, doc: doc, layers: layers) }
        return ["snapshot": .int(Int(snap.id)), "name": .string(snap.name)]
    }

    /// Clicking a snapshot: the document returns to it as one new, undoable state named after it.
    static func selectSnapshot(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "history.selectSnapshot"
        let id = try snapshotId(s, cmd, p)
        // A background job is computing from the current state: it must not move under it.
        if s.activeJob != nil { throw EngineError.other("the document is busy with a background job") }
        guard let snap = s.active?.history.snapshot(id) else { throw EngineError.noDocument }
        try s.edit(snap.name) { doc, active in
            // Keep the identity (colour state, views and caches are keyed by it) and the tab name.
            let (did, name) = (doc.id, doc.name)
            doc = snap.doc
            doc.id = did
            doc.name = name
            active = snap.layers.active.flatMap { snap.doc.contains($0) ? $0 : nil } ?? doc.topLayer
        }
        try s.updateActive { st in
            if st.activeLayer == snap.layers.active {
                st.selectedLayerIds = snap.layers.selected
                st.fixSelection()
            }
        }
        return ["snapshot": .int(Int(snap.id)), "name": .string(snap.name)]
    }

    /// Renaming a snapshot (double-click its name).
    static func renameSnapshot(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "history.renameSnapshot"
        let id = try snapshotId(s, cmd, p)
        guard let name = try nameParam(cmd, p) else { throw EngineError.bad(cmd, "`name` is required") }
        let ok = try s.updateActive { st in st.history.renameSnapshot(id, to: name) }
        if !ok { throw EngineError.bad(cmd, "no such snapshot") }
        return ["snapshot": .int(Int(id)), "name": .string(name)]
    }

    /// Deleting a snapshot; the document and its history are unchanged.
    static func deleteSnapshot(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "history.deleteSnapshot"
        let id = try snapshotId(s, cmd, p)
        let left = try s.updateActive { st -> Int in
            _ = st.history.deleteSnapshot(id)
            return st.history.snapshots.count
        }
        return ["snapshot": .int(Int(id)), "snapshots": .int(left)]
    }

    static let canDelete: CommandEnabled = { s, _ in s.active?.history.canUndo == true ? nil : "the oldest state can't be deleted" }

    static func register(into r: inout CommandRegistry) {
        // `history.*` aliases of Edit › Undo / Redo, so a client reaching for the History namespace
        // finds them (`edit.undo` / `edit.redo` remain the menu items and own the shortcuts).
        r.add(CommandSpec("history.undo", "Undo", params: "{} (the same action as `edit.undo`)", module: m, journal: false,
                          enabled: Pre.canUndo) { s, _ in .bool(s.undo()) })
        r.add(CommandSpec("history.redo", "Redo", params: "{} (the same action as `edit.redo`)", module: m, journal: false,
                          enabled: Pre.canRedo) { s, _ in .bool(s.redo()) })
        r.add(CommandSpec("history.deleteState", "Delete State",
                          params: #"{"state":index?} (History entry, 0 = oldest; default the current state) → {states,current}: removes the state and every later one"#,
                          module: m, enabled: canDelete, run: deleteState))
        r.add(CommandSpec("history.newDocument", "New Document from State",
                          params: #"{"state":index?,"name":str?} (History entry, 0 = oldest; default the current state) → {document,name}"#,
                          module: m, enabled: Pre.hasDoc, run: newDocument))
        r.add(CommandSpec("history.newSnapshot", "New Snapshot",
                          params: #"{"name":str?="Snapshot N","from":"fullDocument"|"mergedLayers"|"currentLayer"="fullDocument"} → {snapshot,name}: a named copy of the document for the session (not a history state)"#,
                          module: m, enabled: Pre.hasDoc, run: newSnapshot))
        r.add(CommandSpec("history.selectSnapshot", "Select Snapshot",
                          params: #"{"snapshot":id} → {snapshot,name}: the document returns to the snapshot as a new history state named after it"#,
                          module: m, enabled: Pre.hasDoc, run: selectSnapshot))
        r.add(CommandSpec("history.renameSnapshot", "Rename Snapshot", params: #"{"snapshot":id,"name":str} → {snapshot,name}"#,
                          module: m, enabled: Pre.hasDoc, run: renameSnapshot))
        r.add(CommandSpec("history.deleteSnapshot", "Delete Snapshot",
                          params: #"{"snapshot":id} → {snapshot,snapshots}: the document and its history are unchanged"#,
                          module: m, enabled: Pre.hasDoc, run: deleteSnapshot))
    }
}
