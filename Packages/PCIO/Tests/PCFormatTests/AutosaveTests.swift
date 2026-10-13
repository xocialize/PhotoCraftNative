// Background autosave and crash recovery.
// Port of photocraft-format (crates/format/tests/autosave.rs and the tests of
// crates/format/src/autosave.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import Testing

@Suite struct AutosaveTests {
    @Test func autosaveThenRecover() throws {
        let dir = tempDir("recovery")
        let doc = richDoc(.rgb, .u16)
        let saver = Autosaver(dir, key: "doc-1")
        saver.request(doc, revision: 7, originalPath: "/work/a.pcraft")
        let stats = try #require(saver.flush(), "a save ran").get()
        #expect(stats.tilesWritten > 0)
        let entries = PcraftFormat.listRecovery(dir)
        #expect(entries.count == 1)
        #expect(entries[0].info.revision == 7)
        #expect(entries[0].info.originalPath == "/work/a.pcraft")
        #expect(entries[0].info.documentName == "Rich")
        #expect(try PcraftFormat.recover(entries[0]) == doc)
        try PcraftFormat.discardRecovery(dir, entries[0])
        #expect(PcraftFormat.listRecovery(dir).isEmpty)
        remove(dir)
    }

    /// A queued snapshot can fail later; callers must observe and retry that revision.
    @Test func backgroundSaveOutcomesReportFailureThenRecovery() throws {
        let root = tempDir("retry-failed-write")
        let blocked = root.appendingPathComponent("recovery")
        try Data("not a directory".utf8).write(to: blocked)
        let saver = Autosaver(blocked, key: "doc")
        let doc = richDoc(.rgb, .u8)
        try saver.requestChecked(doc, revision: 7, originalPath: nil)

        func receive() throws -> (UInt64, Result<Void, AutosaveFailure>) {
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                if let outcome = saver.takeCompleted().first { return (outcome.revision, outcome.result) }
                Thread.sleep(forTimeInterval: 0.01)
            }
            Issue.record("autosave worker did not report its completed write in time")
            throw AutosaveFailure("timeout")
        }
        let (revision, result) = try receive()
        #expect(revision == 7)
        #expect((try? result.get()) == nil, "the recovery location is not a directory")

        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try saver.requestChecked(doc, revision: 7, originalPath: nil)
        let (revision2, result2) = try receive()
        #expect(revision2 == 7)
        try result2.get()
        #expect(PcraftFormat.listRecovery(blocked).count == 1)
        #expect(try PcraftFormat.recover(PcraftFormat.listRecovery(blocked)[0]) == doc)
        saver.flush()
        remove(root)
    }

    @Test func repeatedAutosavesAreIncrementalAndCoalesced() throws {
        let dir = tempDir("coalesce")
        let saver = Autosaver(dir, key: "k")
        var doc = richDoc(.rgb, .u8)
        for i in 0 ..< 5 {
            doc.withRaster(of: doc.layers[1].id) { $0.setPixel(x: Int32(i), y: 0, [1, 0, 0, 1]) }
            saver.request(doc, revision: UInt64(i), originalPath: nil)
        }
        _ = try #require(saver.flush()).get()
        let e = PcraftFormat.listRecovery(dir)
        #expect(e[0].info.revision == 4, "newest snapshot wins")
        #expect(try PcraftFormat.recover(e[0]) == doc)
        remove(dir)
    }

    @Test func discardRemovesEverything() throws {
        let dir = tempDir("discard")
        let saver = Autosaver(dir, key: "x y/z")
        saver.request(richDoc(.grayscale, .u8), revision: 1, originalPath: nil)
        let path = saver.bundlePath
        #expect(path.lastPathComponent.hasPrefix("x_y_z"))
        try saver.discard()
        #expect(PcraftFormat.listRecovery(dir).isEmpty)
        #expect(!FS.exists(path.path))
        remove(dir)
    }

    @Test func listIgnoresJunk() throws {
        let dir = tempDir("junk")
        try Data("{}".utf8).write(to: dir.appendingPathComponent("bogus.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("other.txt"))
        #expect(PcraftFormat.listRecovery(dir).isEmpty)
        #expect(PcraftFormat.listRecovery(dir.appendingPathComponent("missing")).isEmpty)
        remove(dir)
    }

    /// `doc` as document `id` with pixel (x, 0) of its paint layer set, so versions are told apart.
    static func edit(_ doc: Document, _ id: UInt64, _ x: Int32) -> Document {
        var doc = doc
        doc.id = DocId(id)
        doc.withRaster(of: doc.layers[1].id) { $0.setPixel(x: x, y: 0, [1, 0, 0, 1]) }
        return doc
    }

    static func version(_ id: UInt64, _ x: Int32, _ mode: ColorMode) -> Document { edit(richDoc(mode, .u8), id, x) }

    /// Saves one snapshot under `key` and waits for it.
    static func saveOnce(_ dir: URL, _ key: String, _ doc: Document) throws {
        let saver = Autosaver(dir, key: key)
        saver.request(doc, revision: 1, originalPath: nil)
        _ = try #require(saver.flush()).get()
    }

    /// The recovered documents by entry key, ids cleared (they're reassigned on open).
    static func recovered(_ store: RecoveryStore) -> [String: Document] {
        var out: [String: Document] = [:]
        for (e, var doc) in store.recover() {
            doc.id = DocId(0)
            out[e.info.key] = doc
        }
        return out
    }

    static func same(_ doc: Document) -> Document {
        var doc = doc
        doc.id = DocId(0)
        return doc
    }

    @Test func recoveredEntriesSurviveASecondCrashUntilSavedOrClosed() throws {
        let dir = tempDir("second-crash")
        let (a, b) = (AutosaveTests.version(1, 3, .rgb), AutosaveTests.version(2, 5, .grayscale))
        // Launch 1 autosaves two unsaved documents, then crashes (dropping waits for the writes).
        do {
            let launch = RecoveryStore(dir)
            launch.autosave(a, revision: 4, originalPath: nil)
            launch.autosave(b, revision: 6, originalPath: "/work/b.pcraft")
        }
        #expect(PcraftFormat.listRecovery(dir).count == 2)
        // Launch 2 recovers both and crashes before its first autosave: nothing may be lost.
        let keys: [String]
        do {
            let launch = RecoveryStore(dir)
            let docs = AutosaveTests.recovered(launch)
            #expect(docs.count == 2)
            #expect(PcraftFormat.listRecovery(dir).count == 2, "recovering must not delete the entries")
            for (i, key) in docs.keys.sorted().enumerated() { launch.adopt(10 + UInt64(i), key: key) }
            keys = docs.keys.sorted()
        }
        // Launch 3 still has both, pixels intact; one is edited and autosaved, the other closed.
        let edited = AutosaveTests.edit(a, 20, 9)
        do {
            let launch = RecoveryStore(dir)
            let docs = AutosaveTests.recovered(launch)
            #expect(keys.map { docs[$0] } == [AutosaveTests.same(a), AutosaveTests.same(b)])
            launch.adopt(20, key: keys[0])
            launch.adopt(21, key: keys[1])
            launch.autosave(edited, revision: 9, originalPath: nil)
            try launch.discard(21)
            #expect(PcraftFormat.listRecovery(dir).count == 1, "closing removes the adopted entry")
        }
        // The autosave replaced the adopted entry in place: no duplicate, newest content.
        let entries = PcraftFormat.listRecovery(dir)
        #expect(entries.count == 1)
        #expect(entries.first?.info.key == keys[0] && entries.first?.info.revision == 9)
        // Launch 4 recovers it once more and saves it: the entry goes.
        let launch = RecoveryStore(dir)
        #expect(Array(AutosaveTests.recovered(launch).values) == [AutosaveTests.same(edited)])
        launch.adopt(30, key: keys[0])
        try launch.discard(30)
        #expect(PcraftFormat.listRecovery(dir).isEmpty)
        remove(dir)
    }

    @Test func newDocumentsNeverOverwriteSurvivingEntries() throws {
        let dir = tempDir("collision")
        // An earlier launch (including builds that keyed entries by bare document id) left `doc-1`.
        let old = AutosaveTests.version(1, 3, .rgb)
        try AutosaveTests.saveOnce(dir, "doc-1", old)
        // A store from another launch left an entry for its own document 1 too.
        let other = AutosaveTests.version(1, 6, .grayscale)
        RecoveryStore(dir).autosave(other, revision: 2, originalPath: nil)
        #expect(PcraftFormat.listRecovery(dir).count == 2)
        // This launch adopts `doc-1` for its document 5, and its own new document 1 autosaves.
        let fresh = AutosaveTests.version(1, 8, .rgb)
        do {
            let launch = RecoveryStore(dir)
            launch.adopt(5, key: "doc-1")
            launch.autosave(fresh, revision: 3, originalPath: nil)
        }
        let docs = AutosaveTests.recovered(RecoveryStore(dir))
        #expect(docs.count == 3, "the new document got an entry of its own")
        #expect(docs["doc-1"] == AutosaveTests.same(old), "the adopted entry is untouched")
        #expect(docs.values.contains(AutosaveTests.same(other)))
        #expect(docs.values.contains(AutosaveTests.same(fresh)))
        // Closing the new document removes only its own entry.
        let launch = RecoveryStore(dir)
        launch.adopt(5, key: "doc-1")
        launch.autosave(fresh, revision: 3, originalPath: nil)
        try launch.discard(1)
        #expect(PcraftFormat.listRecovery(dir).count == 3)
        try launch.discard(5)
        #expect(PcraftFormat.listRecovery(dir).count == 2)
        remove(dir)
    }

    @Test func sidecarsCannotPointAtOtherBundles() throws {
        let dir = tempDir("sidecar-key")
        let inner = dir.appendingPathComponent("Recovery")
        try AutosaveTests.saveOnce(dir, "outside", richDoc(.rgb, .u8))
        try AutosaveTests.saveOnce(inner, "k", richDoc(.rgb, .u8))
        let info = try String(contentsOf: inner.appendingPathComponent("k.json"), encoding: .utf8)
        // A copied sidecar (its name isn't its key) and one whose key leaves the directory.
        try info.write(to: inner.appendingPathComponent("copy.json"), atomically: false, encoding: .utf8)
        try info.replacingOccurrences(of: "\"k\"", with: "\"../outside\"").write(to: inner.appendingPathComponent("escape.json"), atomically: false, encoding: .utf8)
        #expect(PcraftFormat.listRecovery(inner).map(\.info.key) == ["k"])
        remove(dir)
    }

    /// Once the manifest is committed the save has succeeded: an unreferenced object that cannot
    /// be removed (here a folder squatting on a tile name) must not turn the directory save into a
    /// reported failure.
    @Test func failedCleanupAfterCommitDoesNotFailTheSave() throws {
        let parent = tempDir("cleanup-best-effort")
        let dir = parent.appendingPathComponent("doc.pcraft")
        let doc = richDoc(.rgb, .u8)
        let w = PcraftWriter()
        try w.saveDir(doc, dir)
        let stuck = dir.appendingPathComponent("tiles").appendingPathComponent(String(repeating: "0", count: 64) + ".zst")
        try FileManager.default.createDirectory(at: stuck.appendingPathComponent("inner"), withIntermediateDirectories: true)
        let stats = try w.saveDir(doc, dir)
        #expect(stats.objectsRemoved == 0, "nothing was actually removed")
        #expect(try PcraftFormat.load(contentsOf: dir) == doc)
        remove(parent)
    }

    @Test func aWriteFailureIsReportedNotSilent() throws {
        // photocraft's spawn-failure test: a failed write reaches `lastResult`/`flush`, so recovery
        // health checks never see a broken autosave as working.
        let root = tempDir("autosave-failure")
        let blocked = root.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocked)
        let saver = Autosaver(blocked, key: "k")
        saver.request(richDoc(.rgb, .u8), revision: 1, originalPath: nil)
        let r = try #require(saver.flush())
        #expect((try? r.get()) == nil)
        #expect(throws: AutosaveFailure.self) { try saver.requestChecked(richDoc(.rgb, .u8), revision: 2, originalPath: nil) }
        remove(root)
    }

    @Test func sweepRemovesOrphanedBundlesAndForeignTempFilesOnly() throws {
        let dir = tempDir("sweep")
        let doc = Document(name: "Kept", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
        let saver = Autosaver(dir, key: "kept")
        saver.request(doc, revision: 1, originalPath: nil)
        _ = try #require(saver.flush()).get()
        // A first autosave that crashed before its sidecar was written.
        let orphan = dir.appendingPathComponent("doc-crashed-1.pcraft")
        try FileManager.default.createDirectory(at: orphan.appendingPathComponent("tiles"), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: orphan.appendingPathComponent("tiles/abc.zst"))
        // Stale temp files: another process's (swept) and this process's (kept, may be in flight).
        let foreign = [dir.appendingPathComponent(".kept.json.4294967294-3.pcsave.tmp"),
                       dir.appendingPathComponent("kept.pcraft/.manifest.json.4294967294-0.pcsave.tmp")]
        let own = dir.appendingPathComponent(".kept.json.\(getpid())-9.pcsave.tmp")
        for p in foreign + [own] { try Data("tmp".utf8).write(to: p) }
        // Not ours to judge: unrelated files.
        let other = dir.appendingPathComponent("notes.txt")
        try Data("user file".utf8).write(to: other)

        // Fresh data is never swept.
        Autosave.sweepOrphans(dir, minAge: 3600)
        #expect(FS.isDir(orphan.path) && foreign.allSatisfy { FS.isFile($0.path) })

        Autosave.sweepOrphans(dir, minAge: 0)
        #expect(!FS.exists(orphan.path), "a bundle without a sidecar is swept")
        #expect(foreign.allSatisfy { !FS.exists($0.path) }, "another process's temp files are swept")
        #expect(FS.isFile(own.path), "this process's temp files are kept")
        #expect(FS.isFile(other.path))
        let entries = PcraftFormat.listRecovery(dir)
        #expect(entries.count == 1, "the complete entry survives")
        #expect(try PcraftFormat.recover(entries[0]) == doc)
        remove(dir)
    }
}
