// Port of photocraft-engine (crates/engine/src/smart_cmds.rs `edit_contents`, `commit_child`, `on_close`, `SmartLink`; crates/engine/src/link_watch.rs `update_changed`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edit Contents opens a smart object's contents as a document of its own; saving it (Save
// Contents) or closing it after an edit writes it back into every instance of those contents in
// the parent document, as one undoable step there. Update Changed Linked Content re-renders the
// linked smart objects whose files changed since they were last seen. photocraft stamps a file
// with its size and modification time; the session's file service has no metadata call (and the
// automation layer's sandbox must hold), so here a file's stamp is its size and a SHA-256 of its
// bytes, read through the service: a rewrite with identical bytes isn't a change.

import CryptoKit
import Foundation
import PCDocument
import PCFoundation

extension SmartCommands {
    /// An open Edit Contents document and the shared contents it updates when saved or closed.
    struct SmartLink: Equatable, Sendable {
        var child: DocId
        var parent: DocId
        var layer: LayerId
        var contentsId: SmartContentsId
    }

    /// The session's open Edit Contents documents (photocraft `Session::smart_links`).
    enum SmartLinksKey: StateKey {
        static let defaultValue: [SmartLink] = []
    }

    /// The links of the session (for tests and the app).
    static func smartLinks(_ s: Session) -> [SmartLink] { s.state[SmartLinksKey.self] }

    static func editContents(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.smartObjects.editContents"
        let id = try s.layerParam(p)
        guard let st = s.active else { throw EngineError.noDocument }
        let parent = st.doc.id
        let sm = try smart(st.doc, id)
        let contentsId = sm.contentsId
        // Already open for editing: switch to that document rather than opening another copy.
        if let link = s.state[SmartLinksKey.self].first(where: { $0.parent == parent && $0.contentsId == contentsId }),
           let index = s.index(of: link.child) {
            _ = s.setActive(index)
            return ["document": .int(index), "parentLayer": .id(id)]
        }
        guard let (name, bytes) = try authorizedSourceBytes(s, cmd, st.doc.metadata, sm.source) else {
            throw other("the smart object's contents are unavailable")
        }
        var child = try decodeSource(name, bytes, services: s.services)
        // Bundles keep their document id; each open copy needs its own.
        child.id = .fresh()
        child.name = name
        let index = s.addDocument(child)
        // Admission may replace an id already owned by another open document.
        guard index < s.documents.count else { throw EngineError.noDocument }
        let childId = s.documents[index].id
        s.state[SmartLinksKey.self].removeAll { $0.child == childId }
        s.state[SmartLinksKey.self].append(SmartLink(child: childId, parent: parent, layer: id, contentsId: contentsId))
        return ["document": .int(index), "parentLayer": .id(id)]
    }

    /// Writes an Edit Contents document back into all its parent instances (one undoable step in
    /// the parent) and marks it saved. false if `index` isn't an Edit Contents document
    /// (photocraft `commit_child`).
    @discardableResult
    static func commitChild(_ s: Session, _ index: Int) throws -> Bool {
        guard index >= 0, index < s.documents.count else { return false }
        let child = s.documents[index].doc
        guard let link = s.state[SmartLinksKey.self].first(where: { $0.child == child.id }) else { return false }
        guard let parent = s.index(of: link.parent) else { throw other("the smart object's document was closed") }
        let bytes = try encodeSource(child)
        let services = s.services
        let prev = s.activeIndex
        s.activeIndex = parent
        defer { s.activeIndex = prev }
        try s.edit("Edit Contents") { doc, _ in
            let ids = instances(doc, link.contentsId)
            if ids.isEmpty { throw other("the smart object's instances were removed") }
            for id in ids {
                let sm = try smart(doc, id)
                let name: String
                if case .embedded(let fileName, _) = sm.source { name = fileName } else { name = child.name }
                let stem = name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name
                try updateSmart(&doc, id) { $0.source = .embedded(fileName: "\(stem).pcraft", bytes: bytes) }
                doc.updateLayer(id) { detachPSD(&$0) }
                try refreshOrFail(&doc, id, services: services)
            }
        }
        try? s.updateDocument(at: index) { $0.savedRevision = $0.revision }
        return true
    }

    /// Before a document closes: an edited Edit Contents document updates its parent (photocraft
    /// `on_close`).
    static func onClose(_ s: Session, _ index: Int) {
        guard index >= 0, index < s.documents.count else { return }
        let st = s.documents[index]
        let id = st.id
        if st.isDirty && s.state[SmartLinksKey.self].contains(where: { $0.child == id }) { _ = try? commitChild(s, index) }
        s.state[SmartLinksKey.self].removeAll { $0.child == id || $0.parent == id }
    }

    /// photocraft `is_smart_child`: the active document is Edit Contents contents.
    static let isSmartChild: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return s.state[SmartLinksKey.self].contains(where: { $0.child == d.id }) ? nil : "this document isn't smart object contents"
    }

    // MARK: Linked files changed on disk (photocraft link_watch.rs)

    /// What a linked file looked like when last seen.
    struct LinkStamp: Hashable, Sendable {
        var size: Int
        var digest: [UInt8]
    }

    struct LinkStampKey: Hashable, Sendable {
        var doc: DocId
        var path: String
    }

    /// The stamps of linked files per open document (photocraft `Session::link_stamps`).
    enum LinkStampsKey: StateKey {
        static let defaultValue: [LinkStampKey: LinkStamp] = [:]
    }

    static func stamp(_ path: String, _ fs: any FileSystemService) -> LinkStamp? {
        guard !path.isEmpty, let data = try? fs.read(path) else { return nil }
        return LinkStamp(size: data.count, digest: Array(SHA256.hash(data: data)))
    }

    /// The document's linked files with the layers placing each, by path (photocraft
    /// `linked_files`).
    static func linkedFiles(_ d: Document) -> [(String, [LayerId])] {
        var byFile: [String: [LayerId]] = [:]
        for e in d.walk() {
            if case .smart(let sm) = e.layer.content, case .linked(let path) = sm.source { byFile[path, default: []].append(e.layer.id) }
        }
        return byFile.keys.sorted().map { ($0, byFile[$0] ?? []) }
    }

    /// photocraft `update_changed`.
    static func updateChanged(_ s: Session) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let fs = s.services.fileSystem
        let now = linkedFiles(st.doc).map { ($0.0, $0.1, stamp($0.0, fs)) }
        return applyLinkStamps(s, st.id, now)
    }

    /// photocraft `Session::apply_link_stamps`.
    static func applyLinkStamps(_ s: Session, _ doc: DocId, _ now: [(String, [LayerId], LinkStamp?)]) -> JSONValue {
        guard s.active?.id == doc else { return ["updated": .array([])] }
        let open = Set(s.documents.map(\.id))
        var stamps = s.state[LinkStampsKey.self]
        var before: [String: LinkStamp] = [:]
        for (k, v) in stamps {
            if k.doc == doc {
                before[k.path] = v
                stamps[k] = nil
            } else if !open.contains(k.doc) {
                stamps[k] = nil
            }
        }
        var changed: [(String, [LayerId])] = []
        for (path, ids, stamp) in now {
            let key = LinkStampKey(doc: doc, path: path)
            switch (before[path], stamp) {
            case (let old?, nil):
                stamps[key] = old
            case (let old, let new?):
                if let old, old != new { changed.append((path, ids)) }
                stamps[key] = new
            case (nil, nil):
                break
            }
        }
        s.state[LinkStampsKey.self] = stamps
        let services = s.services
        var updated: [LayerId] = []
        for (path, ids) in changed {
            do {
                try s.edit("Update Modified Content") { d, _ in
                    for id in ids where try !refresh(&d, id, services: services) { throw other("\(path) can't be read") }
                }
                updated += ids
            } catch {
                // A file still being written is tried again when it next changes.
            }
        }
        return ["updated": .ids(updated)]
    }
}
