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

import Foundation
import PCDocument
import PCFormat
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

/// The per-document incremental writers of package saves.
enum PackageWritersKey: StateKey {
    static let defaultValue: PackageWriters? = nil
}

/// Holds the non-Sendable `PcraftWriter`s (they live on the session's isolation domain).
final class PackageWriters: @unchecked Sendable {
    var byDocument: [UInt64: PcraftWriter] = [:]
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

    /// Saves `doc` as a `.pcraft` package at `path` through document `id`'s writer: only tiles
    /// that changed since its last save are hashed and written. The previews are the single-file
    /// export's.
    func savePackage(_ doc: Document, _ path: String, id: UInt64) throws -> SaveStats {
        guard let url = services.fileSystem.localURL(path) else {
            throw EngineError.other("\(path): .pcraft packages can't be saved here; save a single-file .pcraft")
        }
        let previews: SaveOptions
        do { previews = try DocumentIO.pcraftPreviews(doc, options: EngineIO.options(services)) } catch { throw EngineIO.wrap(error, "save `\(path)`") }
        let box = state[PackageWritersKey.self] ?? PackageWriters()
        state[PackageWritersKey.self] = box
        // Writers of closed documents go.
        let open = Set(documents.map(\.id.rawValue))
        box.byDocument = box.byDocument.filter { open.contains($0.key) }
        let writer = box.byDocument[id] ?? PcraftWriter()
        box.byDocument[id] = writer
        do {
            return try writer.save(doc, to: url, as: .package, previews)
        } catch {
            throw EngineError.other("save `\(path)`: \(error)")
        }
    }

    /// Saves `doc` as a single-file `.pcraft` at `path` (local file `url`), written into its
    /// temporary file as it is encoded and then renamed into place: the same file the export
    /// writes, with the same previews and errors, but never held in memory whole.
    func saveSingleFile(_ doc: Document, _ path: String, _ url: URL) throws {
        let previews: SaveOptions
        do { previews = try DocumentIO.pcraftPreviews(doc, options: EngineIO.options(services)) } catch { throw EngineIO.wrap(error, "save `\(path)`") }
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
