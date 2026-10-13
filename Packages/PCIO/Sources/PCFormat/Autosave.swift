// Autosave and crash recovery (photocraft architecture §9): the same incremental writer saves a
// document snapshot into a recovery directory on a background thread, so the UI never blocks.
//
// Layout: `<recovery dir>/<key>.pcraft/` (directory bundles, so repeated autosaves write only
// changed tiles) plus `<key>.json` with `RecoveryInfo`.
//
// `RecoveryStore` is the app-facing lifecycle: an entry is only deleted once the document is
// saved or closed, never just because it was recovered.
// Port of photocraft-format (crates/format/src/autosave.rs), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

import Foundation
import PCDocument
import Synchronization

/// Sidecar describing an autosave.
public struct RecoveryInfo: Codable, Equatable, Sendable {
    public var key: String
    public var documentName: String
    /// Where the user last saved the document, if anywhere.
    public var originalPath: String?
    /// Seconds since the Unix epoch.
    public var savedAt: UInt64
    public var revision: UInt64

    public init(key: String, documentName: String, originalPath: String?, savedAt: UInt64, revision: UInt64) {
        self.key = key; self.documentName = documentName; self.originalPath = originalPath; self.savedAt = savedAt; self.revision = revision
    }

    enum CodingKeys: String, CodingKey {
        case key, documentName = "document_name", originalPath = "original_path", savedAt = "saved_at", revision
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(documentName, forKey: .documentName)
        try c.encode(originalPath, forKey: .originalPath)
        try c.encode(savedAt, forKey: .savedAt)
        try c.encode(revision, forKey: .revision)
    }
}

/// One recoverable document found by `Autosave.listRecovery`.
public struct RecoveryEntry: Equatable, Sendable {
    public var info: RecoveryInfo
    public var bundle: URL

    public init(info: RecoveryInfo, bundle: URL) { self.info = info; self.bundle = bundle }
}

/// Why an autosave request or write failed (photocraft reports these as strings).
public struct AutosaveFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Background autosaver for one document. Requests are coalesced: if saves arrive faster than
/// they complete, only the newest snapshot is written.
public final class Autosaver: Sendable {
    let dir: URL
    public let key: String
    private let state: State

    /// The queue shared with the worker thread (which holds only this, so dropping the
    /// `Autosaver` stops the thread).
    final class State: @unchecked Sendable {
        struct Job {
            var snapshot: Document
            var info: RecoveryInfo
            var opts: SaveOptions
        }

        let cond = NSCondition()
        var pending: Job?
        var accepting = true
        var running = true
        var last: Result<SaveStats, AutosaveFailure>?
        /// Per-request write outcomes, delivered without blocking the caller.
        var completed: [(revision: UInt64, result: Result<Void, AutosaveFailure>)] = []

        func shutdown() {
            cond.lock()
            accepting = false
            cond.broadcast()
            while running { cond.wait() }
            cond.unlock()
        }

        func work(bundle: URL, sidecar: URL) {
            let writer = PcraftWriter()
            while true {
                cond.lock()
                while pending == nil && accepting { cond.wait() }
                guard let job = pending else {
                    running = false
                    cond.broadcast()
                    cond.unlock()
                    return
                }
                pending = nil
                cond.unlock()
                let r: Result<SaveStats, AutosaveFailure>
                do throws(FormatError) {
                    do throws(IOError) { try FS.createDirAll(bundle.path) } catch { throw .io(error) }
                    let stats = try writer.saveDir(job.snapshot, bundle, job.opts)
                    let e = JSONEncoder()
                    e.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let json: [UInt8]
                    do { json = [UInt8](try e.encode(job.info)) } catch { throw .json(FormatError.jsonMessage(error)) }
                    do throws(IOError) { try AtomicSave.atomicWrite(sidecar, json) } catch { throw .io(error) }
                    r = .success(stats)
                } catch {
                    r = .failure(AutosaveFailure(error.description))
                }
                cond.lock()
                completed.append((job.info.revision, r.map { _ in () }))
                last = r
                cond.unlock()
            }
        }
    }

    /// `key` identifies the document across autosaves (e.g. its document id).
    public init(_ recoveryDir: URL, key: String) {
        dir = recoveryDir
        self.key = Autosave.sanitize(key)
        let bundle = dir.appendingPathComponent("\(self.key).pcraft")
        let sidecar = dir.appendingPathComponent("\(self.key).json")
        let state = State()
        self.state = state
        let thread = Thread { state.work(bundle: bundle, sidecar: sidecar) }
        thread.name = "autosave-\(self.key)"
        // Room for the deepest layer tree a bundle may hold (debug builds use more stack per level).
        thread.stackSize = 8 << 20
        thread.start()
    }

    deinit { state.shutdown() }

    public var bundlePath: URL { dir.appendingPathComponent("\(key).pcraft") }

    /// Queues a snapshot for saving (returns immediately). Callers that only need best-effort
    /// autosaving can use this; the app uses `requestChecked`.
    public func request(_ snapshot: Document, revision: UInt64, originalPath: String?, options: SaveOptions = SaveOptions()) {
        try? requestChecked(snapshot, revision: revision, originalPath: originalPath, options: options)
    }

    /// Queues a snapshot, reporting a worker that has stopped. Success means queued, not written:
    /// use `takeCompleted` for write outcomes.
    public func requestChecked(_ snapshot: Document, revision: UInt64, originalPath: String?,
                               options: SaveOptions = SaveOptions()) throws(AutosaveFailure) {
        let info = RecoveryInfo(key: key, documentName: snapshot.name, originalPath: originalPath,
                                savedAt: UInt64(max(0, Date().timeIntervalSince1970)), revision: revision)
        state.cond.lock()
        defer { state.cond.unlock() }
        guard state.accepting else { throw AutosaveFailure("autosave worker is stopped") }
        // Coalesce: a newer snapshot replaces one not yet started.
        state.pending = State.Job(snapshot: snapshot, info: info, opts: options)
        state.cond.signal()
    }

    /// Drains completed write results without waiting for the worker.
    public func takeCompleted() -> [(revision: UInt64, result: Result<Void, AutosaveFailure>)] {
        state.cond.lock()
        defer { state.cond.unlock() }
        let out = state.completed
        state.completed = []
        return out
    }

    /// Result of the most recent completed save.
    public var lastResult: Result<SaveStats, AutosaveFailure>? {
        state.cond.lock()
        defer { state.cond.unlock() }
        return state.last
    }

    /// Finishes pending saves and stops the thread; returns the last result.
    @discardableResult
    public func flush() -> Result<SaveStats, AutosaveFailure>? {
        state.shutdown()
        return lastResult
    }

    /// The document was saved normally or closed: drop its recovery data.
    public func discard() throws(FormatError) {
        state.shutdown()
        try Autosave.removeEntry(dir, key)
    }
}

/// The crash-recovery autosaves of one app session, keyed by document id.
///
/// New documents save under `doc-<session>-<id>`, with a `<session>` unique to this store: ids
/// restart every launch, so a new document must never overwrite an entry an earlier launch left.
/// A recovered document adopts the entry it was loaded from. Its autosaves replace that entry in
/// place (each save is atomic, so the old copy stays loadable until the new one is complete), and
/// saving or closing it removes the entry. Nothing is deleted just because it was recovered, so a
/// second crash before the next autosave loses nothing.
public final class RecoveryStore {
    let dir: URL
    let session: String
    var savers: [UInt64: Autosaver] = [:]
    var adopted: [UInt64: String] = [:]

    private static let stores = Atomic<UInt64>(0)

    public init(_ recoveryDir: URL) {
        let t = UInt64(max(0, Date().timeIntervalSince1970 * 1e9))
        let n = RecoveryStore.stores.wrappingAdd(1, ordering: .relaxed).oldValue
        session = "\(String(t, radix: 16))_\(String(getpid(), radix: 16))_\(String(n, radix: 16))"
        dir = recoveryDir
        Autosave.sweepOrphans(dir, minAge: Autosave.orphanAge)
    }

    /// Loads every recoverable document, newest first, with the entry it came from. Nothing is
    /// deleted: `adopt` each document the app opens. Entries that fail to load stay on disk.
    public func recover() -> [(RecoveryEntry, Document)] {
        Autosave.listRecovery(dir).compactMap { e in (try? Autosave.recover(e)).map { (e, $0) } }
    }

    /// Document `docId` was opened from the recovery entry `key`: its autosaves now replace that
    /// entry, and `discard` removes it.
    public func adopt(_ docId: UInt64, key: String) { adopted[docId] = Autosave.sanitize(key) }

    /// Queues an autosave of `doc` (returns immediately; see `Autosaver.request`).
    public func autosave(_ doc: Document, revision: UInt64, originalPath: String?) {
        try? autosaveChecked(doc, revision: revision, originalPath: originalPath)
    }

    /// Queues a snapshot, reporting enqueue failures to the application.
    public func autosaveChecked(_ doc: Document, revision: UInt64, originalPath: String?) throws(AutosaveFailure) {
        let id = doc.id.rawValue
        let saver: Autosaver
        if let s = savers[id] {
            saver = s
        } else {
            saver = Autosaver(dir, key: adopted[id] ?? "doc-\(session)-\(id)")
            savers[id] = saver
        }
        try saver.requestChecked(doc, revision: revision, originalPath: originalPath)
    }

    /// Completed write outcomes as (document id, revision, outcome), without blocking.
    public func takeCompleted() -> [(docId: UInt64, revision: UInt64, result: Result<Void, AutosaveFailure>)] {
        savers.flatMap { id, saver in saver.takeCompleted().map { (id, $0.revision, $0.result) } }
    }

    /// Document `docId` was saved or closed: remove its recovery data, both its own autosaves and
    /// the entry it adopted.
    public func discard(_ docId: UInt64) throws(FormatError) {
        var first: FormatError?
        if let s = savers.removeValue(forKey: docId) {
            do throws(FormatError) { try s.discard() } catch { first = error }
        }
        if let key = adopted.removeValue(forKey: docId) {
            do throws(FormatError) { try Autosave.removeEntry(dir, key) } catch { first = first ?? error }
        }
        if let first { throw first }
    }

    deinit {
        for s in savers.values { s.flush() }
    }
}

public enum Autosave {
    /// How long recovery data must have been left untouched before `sweepOrphans` may remove it:
    /// far longer than any save takes, so another running instance's in-progress first autosave
    /// (bundle written, sidecar not yet) is never mistaken for an orphan.
    public static let orphanAge: TimeInterval = 24 * 60 * 60

    static func sanitize(_ key: String) -> String {
        let s = String(key.map { c in c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_") ? c : "_" })
        return s.isEmpty ? "untitled" : s
    }

    /// Recoverable documents in `recoveryDir`, newest first. A sidecar must be named after its own
    /// (sanitized) key, so a stray or hand-edited one can never point outside the directory.
    public static func listRecovery(_ recoveryDir: URL) -> [RecoveryEntry] {
        guard let names = try? FS.list(recoveryDir.path) else { return [] }
        var out: [RecoveryEntry] = []
        for name in names where name.hasSuffix(".json") {
            let p = FS.join(recoveryDir.path, name)
            let stem = String(name.dropLast(5))
            guard let bytes = try? FS.read(p), let info = try? JSONDecoder().decode(RecoveryInfo.self, from: Data(bytes)),
                  sanitize(info.key) == info.key, stem == info.key else { continue }
            let bundle = recoveryDir.appendingPathComponent("\(info.key).pcraft")
            if FS.isFile(FS.join(bundle.path, Store.manifest)) { out.append(RecoveryEntry(info: info, bundle: bundle)) }
        }
        out.sort { $0.info.savedAt != $1.info.savedAt ? $0.info.savedAt > $1.info.savedAt : $0.info.key < $1.info.key }
        return out
    }

    /// Loads a recovered document.
    public static func recover(_ entry: RecoveryEntry) throws(FormatError) -> Document {
        try PcraftFormat.load(contentsOf: entry.bundle)
    }

    /// Deletes a recovery entry.
    public static func discardRecovery(_ recoveryDir: URL, _ entry: RecoveryEntry) throws(FormatError) {
        try removeEntry(recoveryDir, entry.info.key)
    }

    static func removeEntry(_ dir: URL, _ key: String) throws(FormatError) {
        let bundle = FS.join(dir.path, "\(key).pcraft")
        do throws(IOError) {
            if FS.exists(bundle) { try FS.removeDirAll(bundle) }
            let sidecar = FS.join(dir.path, "\(key).json")
            if FS.exists(sidecar) { try FS.removeFile(sidecar) }
        } catch {
            throw .io(error)
        }
    }

    /// Best-effort removal of recovery data nothing can ever load or clean up:
    /// - `<key>.pcraft` bundle folders with no `<key>.json` sidecar (a crash during a document's
    ///   first autosave: the sidecar is written after the bundle, and `listRecovery` skips them);
    /// - `*.pcsave.tmp` files left by an interrupted atomic write that another process created.
    /// Only entries untouched for at least `minAge` are removed. Bundles with a sidecar, symlinks
    /// and anything outside `recoveryDir` are never touched; errors are ignored.
    static func sweepOrphans(_ recoveryDir: URL, minAge: TimeInterval) {
        let root = recoveryDir.path
        guard let names = try? FS.list(root) else { return }
        var bundles: [String] = []
        for name in names {
            let path = FS.join(root, name)
            guard let kind = try? FS.lkind(path) else { continue }
            if kind == .file {
                sweepTempFile(path, minAge: minAge)
                continue
            }
            guard kind == .directory, name.hasSuffix(".pcraft") else { continue }
            let key = String(name.dropLast(7))
            if key.isEmpty || sanitize(key) != key { continue }
            // Anything at the sidecar's path (even a broken symlink) keeps the bundle.
            let sidecar: FS.Kind?? = try? FS.lkind(FS.join(root, "\(key).json"))
            let hasSidecar = sidecar != nil && sidecar! != nil
            let parts = [path, FS.join(path, "tiles"), FS.join(path, "blobs")]
            if !hasSidecar && parts.allSatisfy({ untouchedFor($0, minAge: minAge, missingOK: true) }) {
                try? FS.removeDirAll(path)
            } else {
                bundles += parts
            }
        }
        for dir in bundles {
            guard let names = try? FS.list(dir) else { continue }
            for name in names {
                let path = FS.join(dir, name)
                if (try? FS.lkind(path)) == .file { sweepTempFile(path, minAge: minAge) }
            }
        }
    }

    /// Removes `path` if it is an atomic-write temp file of another process, untouched for `minAge`.
    static func sweepTempFile(_ path: String, minAge: TimeInterval) {
        let name = (path as NSString).lastPathComponent
        // `.{stem}.{pid}-{n}.pcsave.tmp`
        guard name.hasPrefix("."), name.hasSuffix(".pcsave.tmp") else { return }
        let rest = name.dropFirst().dropLast(".pcsave.tmp".count)
        guard let dot = rest.lastIndex(of: ".") else { return }
        let owner = rest[rest.index(after: dot)...]
        guard let dash = owner.firstIndex(of: "-"), let pid = UInt32(owner[..<dash]) else { return }
        if pid != UInt32(bitPattern: getpid()) && untouchedFor(path, minAge: minAge, missingOK: false) { unlink(path) }
    }

    /// Whether `path` was last modified at least `minAge` ago. Unreadable times count as recent; a
    /// missing path counts as untouched only when `missingOK`.
    static func untouchedFor(_ path: String, minAge: TimeInterval, missingOK: Bool) -> Bool {
        var st = stat()
        if lstat(path, &st) != 0 { return missingOK && errno == ENOENT }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let age = Date().timeIntervalSince1970 - mtime
        return age >= 0 && age >= minAge
    }
}
