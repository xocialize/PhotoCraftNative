// Port of photocraft's document file life cycle: engine color_cmds.rs `Session::open_document` (the Color Settings open policy), file_cmds.rs `saved_to` / `saves_in_place`, and the app shell's Open / Save / Save As / recent files / crash-recovery autosave (crates/ui-egui/src/file_open.rs, lib.rs `save_as_with` / `write_save` / `AutosaveFn` / `RecoverFn`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// What a frontend calls to open and save documents. Opening imports through PCIO and applies the
// Color Settings open policy; saving makes the file the document's own (its name and path change,
// it is no longer dirty) unless it is a flat file that can't hold the document, which is written
// as a copy. Crash recovery autosaves dirty documents as `.pcraft` bundles in a
// recovery folder (PCFormat's `RecoveryStore`), which the app restores at launch.

import Foundation
import PCDocument
import PCFormat
import PCIOCore
import PCRender

/// The outcome of a save.
public struct SaveOutcome: Sendable, Equatable {
    public var path: String
    public var warnings: [String]
    /// The file is a copy (an export): the document keeps its own path and dirty state.
    public var copy: Bool
    /// What saving the document regenerated (File › Generate › Image Assets: `{files, dir, …}`).
    public var assets: JSONValue?
    /// What a `.pcraft` package save wrote (tiles written and reused); nil for other saves.
    public var stats: SaveStats?
}

/// The session's crash-recovery store (photocraft's `AutosaveFn` / `DiscardAutosaveFn` /
/// `RecoverFn` services, on PCFormat's `RecoveryStore`).
enum RecoveryKey: StateKey {
    static let defaultValue: RecoveryBox? = nil
}

/// Holds the non-Sendable `RecoveryStore` (it lives on the session's isolation domain).
final class RecoveryBox: @unchecked Sendable {
    let dir: URL
    let store: RecoveryStore
    /// The revision last autosaved per document.
    var saved: [UInt64: UInt64] = [:]
    var lastRun = Date.distantPast
    init(_ dir: URL) { self.dir = dir; store = RecoveryStore(dir) }
}

extension Session {
    // MARK: Open

    /// Opens the file at `path` (read through the session's file service, imported by PCIO), with
    /// the Color Settings open policy applied, and makes it the active document (photocraft
    /// `open_path` + `Session::open_document`). Returns the index and the warnings.
    @discardableResult
    public func openFile(_ path: String) throws -> (index: Int, warnings: [String], color: JSONValue) {
        try openFileImport(path).opened
    }

    /// `openFile`, with the import's result (`file.open` reports a `.comp`'s manifest ids from it).
    func openFileImport(_ path: String) throws -> (opened: (index: Int, warnings: [String], color: JSONValue), result: ImportResult) {
        // A local `.pcraft`'s own previews can stand for its first save's (`SaveSlot.opened`).
        let pcraft = EngineIO.fileExtension(path) == PcraftFormat.fileExtension ? services.fileSystem.localURL(path) : nil
        let stamp = pcraft.flatMap(FileStamp.init)
        let r = try EngineIO.importPath(path, services: services)
        let opened = openImported(r, path: path)
        if let pcraft, let stamp, opened.index < documents.count {
            saveSlot(documents[opened.index].id).withLock { $0.opened = (r.document, pcraft, stamp) }
        }
        return (opened, r)
    }

    /// Adds an imported document: a read-only source (Paint.NET, Affinity, Krita) keeps no path to
    /// save back to; the open policy's report joins the warnings.
    @discardableResult
    func openImported(_ r: ImportResult, path: String?) -> (index: Int, warnings: [String], color: JSONValue) {
        let keepPath = r.sourceReadOnly ? nil : path
        let (i, report) = ColorCommands.openDocument(self, r.document, path: keepPath)
        if r.sourceReadOnly { try? updateDocument(at: i) { $0.sourceReadOnly = true } }
        if let path { noteRecent(path) }
        return (i, r.warnings, report)
    }

    // MARK: Save

    /// Saves document `index` (default: the active one) to `path`, or back to its own file when
    /// that is layered (photocraft Save / Save As, `save_as_with` / `write_save`). Unless the
    /// save is a copy (`savesCopy`), the file becomes the document's: its name and path change,
    /// it is no longer dirty, its crash-recovery data goes, and the Save Document script event
    /// and Image Assets run (photocraft `saved`). `tiffLayers` is the TIFF Options answer (nil:
    /// not asked, the layers are kept); `tgaBits` the Targa bits per pixel. A `.pcraft` is saved
    /// in `pcraftForm`, by default its own form or else a package (`pcraftContainer(for:)`;
    /// `savePlan` says what Save does). `saveJob` and `finishSave` are the same save in two
    /// parts, for writing the file on another thread.
    @discardableResult
    public func saveDocument(_ index: Int? = nil, to path: String? = nil, quality: Double? = nil, tiffLayers: Bool? = nil, tgaBits: Int? = nil,
                             forceCopy: Bool = false, pcraftForm: PcraftFormat.Container? = nil) throws -> SaveOutcome {
        let job = try saveJob(index, to: path, quality: quality, tiffLayers: tiffLayers, tgaBits: tgaBits, forceCopy: forceCopy, pcraftForm: pcraftForm)
        return try finishSave(job, try job.run())
    }

    /// The first part of `saveDocument` (same parameters): what to write, decided on the session's
    /// thread, with a snapshot of the document. Run the job anywhere (`SaveJob.run`), then give
    /// what it wrote to `finishSave` on the session's thread.
    public func saveJob(_ index: Int? = nil, to path: String? = nil, quality: Double? = nil, tiffLayers: Bool? = nil, tgaBits: Int? = nil,
                        forceCopy: Bool = false, pcraftForm: PcraftFormat.Container? = nil) throws -> SaveJob {
        guard let i = index ?? activeIndex, i >= 0, i < documents.count else { throw EngineError.noDocument }
        let st = documents[i]
        let target: String
        if let path {
            target = path
        } else {
            guard let own = st.path, EngineIO.savesInPlace(own), !st.sourceReadOnly else {
                throw EngineError.other("Save writes back only to the document's own PSD, PSB or .pcraft file")
            }
            target = own
        }
        var opts = FileCommands.SaveOpts()
        opts.quality = quality
        // Unasked, a TIFF keeps the layers (photocraft's `ExportSettings` default).
        opts.tiffLayers = tiffLayers ?? true
        opts.tgaBits = tgaBits
        opts.imagePreviews = preferences["fileHandling.imagePreviews"]?.stringValue != "never"
        var package: URL?
        if EngineIO.fileExtension(target) == PcraftFormat.fileExtension, try pcraftContainer(for: target, requested: pcraftForm) == .package {
            guard let url = services.fileSystem.localURL(target) else {
                throw EngineError.other("\(target): .pcraft packages can't be saved here; save a single-file .pcraft")
            }
            package = url
        }
        return SaveJob(path: target, document: st.doc, copy: forceCopy || Self.savesCopy(st, target, tiffLayers: tiffLayers), docId: st.id,
                       revision: st.revision, package: package, options: opts, services: services, slot: saveSlot(st.id))
    }

    /// The second part of `saveDocument`: what job `job`'s save means to the session, once it has
    /// written the file. Unless it was a copy, the file becomes the document's (still dirty if it
    /// was edited after the job was taken), and the Save Document script event and Image Assets
    /// run. A document closed meanwhile has nothing to update.
    @discardableResult
    public func finishSave(_ job: SaveJob, _ written: SaveJob.Written) throws -> SaveOutcome {
        var assets: JSONValue?
        if !job.copy, let i = documents.firstIndex(where: { $0.id == job.docId }) {
            // File identity is not a history step; a stale revision (an edit since) stays dirty.
            try updateDocument(at: i) { d in
                if d.revision == job.revision { d.savedTo(job.path) } else { d.path = job.path }
                d.sourceReadOnly = false
            }
            discardRecovery(job.docId)
            noteRecent(job.path)
            // "Save Document" script events and File › Generate › Image Assets.
            assets = AutomateCommands.documentSaved(self, i)
            publish()
        }
        return SaveOutcome(path: job.path, warnings: written.warnings, copy: job.copy, assets: assets, stats: written.stats)
    }

    /// Whether saving document `st` to `path` writes a copy (photocraft `saves_copy`): a flat file
    /// that can't hold the document (its layers, or the layered file it lives in) is a copy, as
    /// in Photoshop, so Save still writes the layered original and the edits stay unsaved
    /// (#2550); so is a TIFF whose layers TIFF Options discards.
    static func savesCopy(_ st: DocState, _ path: String, tiffLayers: Bool?) -> Bool {
        let layered = { (p: String) in EngineIO.savesInPlace(p) || ["tif", "tiff"].contains(EngineIO.fileExtension(p) ?? "") }
        return tiffLayers == false || (!layered(path) && (plainRaster(st.doc) == nil || (st.path.map(layered) ?? false)))
    }

    /// The document's one layer when it is a plain raster a flat file holds as is: visible, opaque,
    /// Normal, without masks, effects, channel restrictions or Blend If (photocraft `plain_raster`).
    public static func plainRaster(_ doc: Document) -> Layer? {
        guard doc.layers.count == 1, let l = doc.layers.first, case .raster = l.content, l.visible, l.opacity >= 1, l.fillOpacity >= 1,
              l.mask == nil, l.vectorMask == nil, l.effects.items.isEmpty, l.effects.psdRaw == nil,
              l.blend == .normal || l.blend == .passThrough,
              LayerGeometry.channelWeights(l, mode: doc.mode) == nil, !LayerGeometry.blendIfActive(l, mode: doc.mode) else { return nil }
        return l
    }

    // MARK: Recent files (Preferences › File Handling)

    /// The recent files, newest first.
    public var recentFiles: [String] { preferences["fileHandling.recentFiles"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    func noteRecent(_ path: String) {
        let cap = max(preferences["fileHandling.recentFileCount"]?.intValue ?? 20, 0)
        var list = recentFiles.filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > cap { list.removeLast(list.count - cap) }
        setRecent(list)
    }

    func setRecent(_ list: [String]) {
        try? preferences.set("fileHandling.recentFiles", .strings(list))
        emit(.preferencesChanged)
    }

    // MARK: Crash recovery

    /// Turns on crash-recovery autosave into `dir` (the app's recovery folder).
    public func enableRecovery(_ dir: URL) {
        state[RecoveryKey.self] = RecoveryBox(dir)
    }

    /// Autosaves every dirty document whose revision changed since its last autosave, when
    /// File Handling's autosave is on and its interval has passed (`force` ignores the interval).
    /// The writes run in the background; `recoveryResults()` reports them.
    public func autosaveDirty(force: Bool = false) {
        guard let box = state[RecoveryKey.self], preferences["fileHandling.autosave"]?.boolValue ?? true else { return }
        let minutes = Double(preferences["fileHandling.autosaveMinutes"]?.intValue ?? 10)
        if !force, Date().timeIntervalSince(box.lastRun) < minutes * 60 { return }
        box.lastRun = Date()
        for d in documents where d.isDirty && box.saved[d.id.rawValue] != d.revision {
            box.store.autosave(d.doc, revision: d.revision, originalPath: d.path)
            box.saved[d.id.rawValue] = d.revision
        }
    }

    /// Finished background autosaves: (document id, revision, error message or nil).
    public func recoveryResults() -> [(doc: UInt64, revision: UInt64, error: String?)] {
        guard let box = state[RecoveryKey.self] else { return [] }
        return box.store.takeCompleted().map { r in
            switch r.result {
            case .success: (r.docId, r.revision, nil)
            case .failure(let e): (r.docId, r.revision, e.description)
            }
        }
    }

    /// The documents a previous run left unsaved (listed without decoding them).
    public func recoverableDocuments() -> [RecoveryEntry] {
        guard let box = state[RecoveryKey.self] else { return [] }
        return PcraftFormat.listRecovery(box.dir)
    }

    /// Opens a recovered document (dirty, at its original path when it had one); its autosaves
    /// replace the entry from now on.
    @discardableResult
    public func restore(_ entry: RecoveryEntry) throws -> Int {
        let doc: Document
        do { doc = try PcraftFormat.recover(entry) } catch { throw EngineError.other("recover \(entry.info.documentName): \(error)") }
        let i = addDocument(doc, path: entry.info.originalPath)
        try updateDocument(at: i) { $0.savedRevision = $0.revision &- 1 }
        state[RecoveryKey.self]?.store.adopt(documents[i].id.rawValue, key: entry.info.key)
        return i
    }

    /// Drops a recovery entry without opening it.
    public func discardRecoverable(_ entry: RecoveryEntry) throws {
        guard let box = state[RecoveryKey.self] else { return }
        do { try PcraftFormat.discardRecovery(box.dir, entry) } catch { throw EngineError.other("\(error)") }
    }

    /// A document's recovery data goes once it is saved or closed.
    func discardRecovery(_ id: DocId) {
        guard let box = state[RecoveryKey.self] else { return }
        try? box.store.discard(id.rawValue)
        box.saved[id.rawValue] = nil
    }
}
