// What File › Save writes (AB-D-0131, AB-T-0240): the native `.pcraft` is the default, saved as a
// macOS document package (a folder, written incrementally); PSD and PSB stay PSD and PSB.
//
//   the document                          Save writes                 the Save panel proposes
//   untitled                              (asks)                      <name>.pcraft, a package
//   opened from a .pcraft package         the package, new tiles only
//   opened from a single-file .pcraft     the single file (shared files stay shareable)
//   opened from PSD / PSB / OpenRaster    PSD / PSB / ORA, with warnings naming what the format can't keep
//   opened from a flat or import-only     (asks)                      <stem>.pcraft, a package
//   file (PNG, JPEG, TIFF, Krita, …)
//
// A package needs a local folder (`FileSystemService.localURL`); sessions without one, and
// automation sessions (`newPcraftContainer = .singleFile`: scripts and agents expect one file), save
// `.pcraft` as a single file. Each open document keeps one `PcraftWriter`, so repeated package saves
// re-hash and re-write only the tiles that changed. A single file on a local disk is streamed into
// place entry by entry (AB-T-0249), so a multi-gigabyte document is never encoded in memory whole.
//
// Saving off the session's thread (AB-T-0259): `Session.saveJob` takes what to write and a snapshot
// of the document; `SaveJob.run` writes it on any thread; `Session.finishSave` applies what the
// save means (the file becomes the document's) back on the session's. `saveDocument` is the three
// in a row, and `file.save` / `file.saveAs` are jobs `Session.start` runs in the background. A
// document's writer and its last previews live in its `SaveSlot`, under a lock its jobs take one at
// a time. The `.pcraft` previews come from one reduced composite; a later save composites again
// only what its edits can have changed, and a just-opened `.pcraft`'s own previews stand for the
// last ones.

import Foundation
import PCDocument
import PCFormat
import PCFoundation
import PCIO
import PCIOCore

/// What File › Save does with a document (`Session.savePlan`).
public struct SavePlan: Sendable, Equatable {
    /// The formats Save writes.
    public enum Format: String, Sendable, Equatable, CaseIterable {
        case pcraftPackage, pcraftSingleFile, psd, psb, openRaster

        /// The file extension.
        public var fileExtension: String {
            switch self {
            case .pcraftPackage, .pcraftSingleFile: PcraftFormat.fileExtension
            case .psd: "psd"
            case .psb: "psb"
            case .openRaster: "ora"
            }
        }
    }

    /// The format Save writes or, when `path` is nil, the one the Save panel proposes.
    public var format: Format
    /// The file Save writes back to; nil when Save asks where (an untitled document, or a file Save
    /// doesn't write back to).
    public var path: String?
    /// The file name the Save panel proposes when it asks.
    public var proposedName: String

    public init(format: Format, path: String?, proposedName: String) {
        self.format = format; self.path = path; self.proposedName = proposedName
    }
}

/// What a document's saves share (`SaveSlot`), by document.
enum SaveSlotsKey: StateKey {
    static let defaultValue: SaveSlots? = nil
}

/// The open documents' save slots (they live on the session's isolation domain; each slot locks
/// itself for the save jobs that use it).
final class SaveSlots: @unchecked Sendable {
    var byDocument: [UInt64: SaveSlot] = [:]
}

/// One document's save state, shared by its save jobs: the package writer, which remembers which
/// tiles are on disk so a save writes only new ones, and the previews of the last `.pcraft` save
/// with the document they show. A document's jobs run one at a time, under the slot's lock, on
/// whichever thread runs them: two saves never write one package at once.
final class SaveSlot: @unchecked Sendable {
    private let lock = NSLock()
    /// The package writer (package saves only).
    var writer: PcraftWriter?
    /// The last previews made, and the document they show.
    var last: (document: Document, previews: PcraftPreviews)?
    /// A `.pcraft` the document was opened from, as it was then: the previews it holds stand for
    /// `last` until a save makes its own, unless the file has changed since.
    var opened: (document: Document, url: URL, stamp: FileStamp)?

    func withLock<R>(_ body: (SaveSlot) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(self)
    }

    /// The `.pcraft` previews of `doc`. The last ones again while nothing they show has changed;
    /// where an edit since can only have changed some pixels (`TransactionBuilder.damage`), the
    /// last ones with those cells composited again; else rendered whole (one reduced composite,
    /// `DocumentIO.pcraftPreviews`).
    func previews(_ doc: Document, _ path: String, _ services: EngineServices) throws -> SaveOptions {
        if last == nil, let opened {
            self.opened = nil
            if FileStamp(opened.url) == opened.stamp, let stored = try? PcraftFormat.readPreviews(contentsOf: opened.url),
               let previews = PcraftPreviews(stored: stored, of: opened.document) {
                last = (opened.document, previews)
            }
        }
        var updating: (previews: PcraftPreviews, damage: PixelRect)?
        if let last {
            let before = SaveSlot.unseen(last.document, as: doc)
            if before == doc { return last.previews.options }
            if let damage = TransactionBuilder.damage(TransactionBuilder.transaction("Save", from: before, to: doc), before: before, after: doc) {
                updating = (last.previews, damage)
            }
        }
        let previews: PcraftPreviews
        do { previews = try DocumentIO.pcraftPreviews(doc, options: EngineIO.options(services), updating: updating) } catch { throw EngineIO.wrap(error, "save `\(path)`") }
        last = (doc, previews)
        return previews.options
    }

    /// `a` with what a composite doesn't show taken from `b`: what saving changes (the name), the
    /// document's identity, the selection, guides, notes and the work path.
    static func unseen(_ a: Document, as b: Document) -> Document {
        var a = a
        a.id = b.id
        a.name = b.name
        a.selection = b.selection
        a.guides = b.guides
        a.notes = b.notes
        a.workPath = b.workPath
        return a
    }

    /// Whether `a` and `b` composite alike: equal but for what `unseen` takes. Their unchanged
    /// tiles are shared, so this compares only what was edited.
    static func rendersAlike(_ a: Document, _ b: Document) -> Bool { unseen(a, as: b) == b }
}

/// When a file was last written, as far as `stat` tells: a package's manifest, or a single file.
struct FileStamp: Equatable, Sendable {
    let size: Int64
    let modified: timespec
    let inode: UInt64

    init?(_ url: URL) {
        var st = stat()
        let isPackage = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let path = isPackage ? url.appendingPathComponent("manifest.json").path : url.path
        guard stat(path, &st) == 0 else { return nil }
        size = st.st_size
        modified = st.st_mtimespec
        inode = UInt64(st.st_ino)
    }

    static func == (a: FileStamp, b: FileStamp) -> Bool {
        a.size == b.size && a.inode == b.inode && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
    }
}

/// A save of one document, taken on the session's thread (`Session.saveJob`) and run on any
/// thread (`run`), so a frontend can save without blocking its own: the document is a snapshot (a
/// value: taking it copies nothing), so edits made while the job runs stay unsaved, and
/// `Session.finishSave` then applies what the save means to the session on its thread. `file.save`
/// and `file.saveAs` are such jobs: `Session.start` / `executeAsync` run them in the background.
public struct SaveJob: Sendable {
    /// The file written.
    public let path: String
    /// The document saved, as it was when the job was taken.
    public let document: Document
    /// The file is a copy (an export): the document keeps its own path and dirty state.
    public let copy: Bool
    let docId: DocId
    let revision: UInt64
    /// A `.pcraft` package at that local folder, or any other file (`FileCommands.saveDoc`).
    let package: URL?
    let options: FileCommands.SaveOpts
    let services: EngineServices
    let slot: SaveSlot

    /// What `run` wrote.
    public struct Written: Sendable {
        /// What the file couldn't keep.
        public var warnings: [String]
        /// A package save's tiles (written, reused); nil for other files.
        public var stats: SaveStats?
    }

    /// Writes the file. One document's jobs run one at a time, in the order they get here; nothing
    /// is written once `ctx` is cancelled.
    public func run(_ ctx: JobContext = JobContext()) throws -> Written {
        try slot.withLock { slot in
            try ctx.check()
            guard let package else {
                let warnings = try FileCommands.saveDoc(services, document, path, options) { try slot.previews(document, path, services) }
                return Written(warnings: warnings, stats: nil)
            }
            let previews = try slot.previews(document, path, services)
            try ctx.check()
            let writer = slot.writer ?? PcraftWriter()
            slot.writer = writer
            do {
                return Written(warnings: [], stats: try writer.save(document, to: package, as: .package, previews))
            } catch {
                throw EngineError.other("save `\(path)`: \(error)")
            }
        }
    }

    /// The previews of a `.pcraft` save of `doc` to `path`: the single-file export's.
    static func previews(_ doc: Document, _ path: String, _ services: EngineServices) throws -> SaveOptions {
        do { return try DocumentIO.pcraftPreviews(doc, options: EngineIO.options(services)) } catch { throw EngineIO.wrap(error, "save `\(path)`") }
    }

    /// Saves `doc` as a single-file `.pcraft` at `path` (local file `url`), written into its
    /// temporary file as it is encoded and then renamed into place: the same file the export
    /// writes, with the same previews and errors, but never held in memory whole.
    static func saveSingleFile(_ doc: Document, _ path: String, _ url: URL, _ previews: SaveOptions) throws {
        // A one-off writer: it keeps nothing for a next save.
        let writer = PcraftWriter()
        writer.setZipCacheBudget(0)
        do {
            try writer.save(doc, to: url, as: .singleFile, previews)
        } catch {
            if case .io(let e) = error { throw EngineError.other("\(path): \(e)") }
            throw EngineIO.wrap(PCIOError.format("pcraft", error.description), "save `\(path)`")
        }
    }
}

extension Session {
    /// What File › Save does with document `index` (default: the active one).
    public func savePlan(_ index: Int? = nil) throws -> SavePlan {
        guard let i = index ?? activeIndex, i >= 0, i < documents.count else { throw EngineError.noDocument }
        let st = documents[i]
        if let path = st.path, EngineIO.savesInPlace(path), !st.sourceReadOnly {
            let format: SavePlan.Format
            switch EngineIO.fileExtension(path) {
            case "psd": format = .psd
            case "psb": format = .psb
            case "ora": format = .openRaster
            default: format = try pcraftContainer(for: path) == .package ? .pcraftPackage : .pcraftSingleFile
            }
            return SavePlan(format: format, path: path, proposedName: DocState.fileName(path))
        }
        let stem = FileCommands.stem(st.path.map(DocState.fileName) ?? st.doc.name)
        return SavePlan(format: newPcraftContainer == .package ? .pcraftPackage : .pcraftSingleFile, path: nil,
                        proposedName: "\(stem.isEmpty ? "Untitled" : stem).\(PcraftFormat.fileExtension)")
    }

    /// The form a `.pcraft` save to `path` writes: `requested` when given; else the form already
    /// at `path` (Save keeps a shared single file single); else `newPcraftContainer`. Throws for a
    /// form the path or the file system can't take.
    public func pcraftContainer(for path: String, requested: PcraftFormat.Container? = nil) throws -> PcraftFormat.Container {
        let fs = services.fileSystem
        let existing: PcraftFormat.Container? = fs.isDirectory(path) ? .package : fs.exists(path) ? .singleFile : nil
        let packages = fs.localURL(path) != nil
        switch requested ?? existing ?? (packages ? newPcraftContainer : .singleFile) {
        case .package:
            guard packages else { throw EngineError.other("\(path): .pcraft packages can't be saved here; save a single-file .pcraft") }
            if existing == .singleFile { throw EngineError.other("\(path) is a single-file .pcraft; save the package under another name") }
            return .package
        case .singleFile:
            if existing == .package { throw EngineError.other("\(path) is a .pcraft package; save the single file under another name") }
            return .singleFile
        }
    }

    /// The save slot of document `id` (created on its first save); the slots of closed documents go.
    func saveSlot(_ id: DocId) -> SaveSlot {
        let slots = state[SaveSlotsKey.self] ?? SaveSlots()
        state[SaveSlotsKey.self] = slots
        let open = Set(documents.map(\.id.rawValue))
        slots.byDocument = slots.byDocument.filter { open.contains($0.key) }
        if let slot = slots.byDocument[id.rawValue] { return slot }
        let slot = SaveSlot()
        slots.byDocument[id.rawValue] = slot
        return slot
    }

    /// Drops document `id`'s save slot (it is closing): its writer and the snapshot its previews show.
    func dropSaveSlot(_ id: DocId) {
        state[SaveSlotsKey.self]?.byDocument[id.rawValue] = nil
    }
}
