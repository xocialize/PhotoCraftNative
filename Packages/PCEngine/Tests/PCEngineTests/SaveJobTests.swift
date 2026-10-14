// Saving off the session's thread (AB-T-0259): a save job writes a snapshot of the document on
// any thread and its bookkeeping comes back on the session's; one document's jobs run one at a
// time; `file.save` runs in the background when started; the `.pcraft` previews are rendered
// again only when something they show has changed.

import Foundation
@testable import PCEngine
import PCDocument
import PCFormat
import PCFoundation
import PCIO
import PCRender
import Synchronization
import Testing

@Suite struct SaveJobTests {
    /// A two-layer document, 1024 × 512, with ink in its first tile.
    func poster() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 1024, "height": 512, "name": "Poster"])
        try s.execute("layer.new.layer", ["name": "Ink"])
        try fill(s, x: 4, color: "#cc2244")
        return s
    }

    func fill(_ s: Session, x: Int, color: String) throws {
        try s.execute("select.rect", ["x": .int(x), "y": 4, "width": 40, "height": 30])
        try s.execute("edit.fill", ["color": .string(color)])
        try s.execute("select.deselect")
    }

    func layers(_ path: String) throws -> [Layer] { try PcraftFormat.load(contentsOf: URL(fileURLWithPath: path)).layers }

    /// The job writes the document as it was when taken; an edit made while it ran stays unsaved.
    @Test func aJobWritesItsSnapshotAndEditsMeanwhileStayUnsaved() throws {
        let dir = try ioDir("job-snapshot")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try poster()
        let path = dir.appendingPathComponent("Poster.pcraft").path
        let job = try s.saveJob(to: path)
        let snapshot = try #require(s.active?.doc)
        try fill(s, x: 300, color: "#2244cc")
        // Written elsewhere, as a frontend's worker would.
        let written = try DispatchQueue.global().sync { try job.run() }
        let outcome = try s.finishSave(job, written)
        #expect(outcome.path == path && !outcome.copy && outcome.stats?.tilesWritten == outcome.stats?.tilesTotal)
        #expect(try layers(path) == snapshot.layers)
        #expect(s.active?.doc.layers != snapshot.layers)
        #expect(s.active?.path == path && s.active?.isDirty == true, "the edit made meanwhile isn't saved")
        // Saved again, it is.
        try s.saveDocument()
        #expect(try s.active?.isDirty == false && layers(path) == s.active?.doc.layers)
    }

    /// `file.save` started in the background returns a job; its result is what `execute` gives.
    @Test func fileSaveRunsAsABackgroundJob() async throws {
        let dir = try ioDir("job-background")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try poster()
        let path = dir.appendingPathComponent("Poster.pcraft").path
        guard case .job(let id) = try s.start("file.saveAs", ["path": .string(path)]) else {
            Issue.record("file.saveAs ran inline")
            return
        }
        let r = try s.waitJob(id)
        #expect(r["path"]?.stringValue == path && r["copy"] == false && r["tiles"]?["written"] != nil)
        #expect(s.active?.path == path && s.active?.isDirty == false && s.active?.doc.name == "Poster.pcraft")
        try fill(s, x: 300, color: "#2244cc")
        let again = try await s.executeAsync("file.save")
        #expect(again["tiles"]?["written"]?.intValue == 1, "\(again)")
        #expect(try s.active?.isDirty == false && layers(path) == s.active?.doc.layers)
        // A flat file too: a copy, written by the job, the document untouched.
        let png = dir.appendingPathComponent("Poster.png").path
        let flat = try await s.executeAsync("file.saveAs", ["path": .string(png)])
        #expect(flat["copy"] == true && FileManager.default.fileExists(atPath: png) && s.active?.path == path)
    }

    /// One document's jobs never write its package at once: started together on two threads,
    /// both save, and the package holds one of the two snapshots whole.
    @Test func oneDocumentsJobsRunOneAtATime() throws {
        let dir = try ioDir("job-serial")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try poster()
        let path = dir.appendingPathComponent("Poster.pcraft").path
        try s.saveDocument(to: path)
        try fill(s, x: 300, color: "#2244cc")
        let a = try s.saveJob()
        try fill(s, x: 600, color: "#22cc44")
        let b = try s.saveJob()
        let box = Mutex<[Int: Result<SaveJob.Written, any Error>]>([:])
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let r = Result { try (i == 0 ? a : b).run() }
            box.withLock { $0[i] = r }
        }
        let results = box.withLock { [$0[0]!, $0[1]!] }
        for r in results { #expect((try? r.get()) != nil) }
        let saved = try layers(path)
        #expect(saved == a.document.layers || saved == b.document.layers)
        try s.finishSave(a, try results[0].get())
        try s.finishSave(b, try results[1].get())
        #expect(s.active?.isDirty == false)
    }

    /// The previews are rendered again only when what they show changed: not for a rename, a
    /// selection or a guide; yes for an edit.
    @Test func previewsAreKeptWhileNothingTheyShowChanges() throws {
        let dir = try ioDir("job-previews")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try poster()
        let path = dir.appendingPathComponent("Poster.pcraft").path
        try s.saveDocument(to: path)
        let id = try #require(s.active?.id)
        let slot = s.saveSlot(id)
        #expect(slot.last?.document.name == "Poster", "the snapshot taken before the save renamed it")
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 50, "height": 50])
        try s.saveDocument()
        #expect(slot.last?.document.name == "Poster", "kept")
        try s.execute("select.deselect")
        try fill(s, x: 300, color: "#2244cc")
        try s.saveDocument()
        #expect(slot.last?.document.name == "Poster.pcraft", "rendered again")
        let png = try #require(slot.last?.previews.options.composite)
        #expect(png.width == 1024 && png.height == 512)

        let doc = try #require(s.active?.doc)
        var renamed = doc
        renamed.name = "Other"
        renamed.guides.horizontal = [12]
        #expect(SaveSlot.rendersAlike(doc, renamed))
        var faded = doc
        faded.layers[0].opacity = 0.5
        #expect(!SaveSlot.rendersAlike(doc, faded))
    }

    /// The largest difference of any channel between two previews, in levels.
    static func levels(_ a: RGBA8Image?, _ b: RGBA8Image?) -> Int {
        guard let a, let b, a.width == b.width, a.height == b.height else { return .max }
        return zip(a.data, b.data).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    /// Previews rendered whole, for comparison.
    static func whole(_ s: Session) throws -> SaveOptions {
        try DocumentIO.pcraftPreviews(try #require(s.active?.doc), options: EngineIO.options(s.services))
    }

    /// realistic20 (effects, adjustments, clipping, groups) at 1280², reduced to 1024 for its preview.
    func realistic(_ s: Session = Session()) -> Session {
        s.addDocument(BenchmarkDocuments.realistic20(size: 1280))
        return s
    }

    func layer(_ s: Session, _ name: String) throws -> LayerId {
        var id: LayerId?
        try #require(s.active?.doc).forEachLayer { _, _, l in if l.name == name { id = l.id } }
        return try #require(id)
    }

    /// After an edit, the previews are the last ones with the damaged cells composited again: the
    /// previews rendered whole, within a level.
    @Test func editedPreviewsAreTheWholeOnesWhereTheEditReaches() throws {
        let dir = try ioDir("job-incremental")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = realistic()
        let path = dir.appendingPathComponent("r.pcraft").path
        try s.saveDocument(to: path)
        let slot = s.saveSlot(try #require(s.active?.id))
        // A fill on a plain layer, a stroke on one with a bevel and a drop shadow, and an opacity change.
        try s.execute("layer.select", ["layer": .id(try layer(s, "particles"))])
        try s.execute("select.rect", ["x": 300, "y": 310, "width": 120, "height": 30])
        try s.execute("edit.fill", ["color": "#0000ff"])
        try s.execute("select.deselect")
        try s.saveDocument()
        #expect(Self.levels(slot.last?.previews.options.composite, try Self.whole(s).composite) <= 1)
        #expect(Self.levels(slot.last?.previews.options.thumbnail, try Self.whole(s).thumbnail) <= 1)
        try s.execute("layer.select", ["layer": .id(try layer(s, "logo"))])
        try s.execute("select.rect", ["x": 1050, "y": 1050, "width": 60, "height": 60])
        try s.execute("edit.fill", ["color": "#00ff00"])
        try s.execute("select.deselect")
        try s.execute("layer.setProps", ["opacity": 0.4])
        try s.saveDocument()
        #expect(Self.levels(slot.last?.previews.options.composite, try Self.whole(s).composite) <= 1)
        #expect(Self.levels(slot.last?.previews.options.thumbnail, try Self.whole(s).thumbnail) <= 1)
        // What was saved is what the slot holds.
        let stored = try PcraftFormat.readPreviews(contentsOf: URL(fileURLWithPath: path))
        #expect(stored.composite == slot.last?.previews.options.composite && stored.thumbnail == slot.last?.previews.options.thumbnail)
    }

    /// A reopened package's own previews stand for its first save's, updated where the edit
    /// reaches; not when the file changed after it was opened.
    @Test func aReopenedPackagesPreviewsStandForItsFirstSave() throws {
        let dir = try ioDir("job-reopened")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = realistic()
        let path = dir.appendingPathComponent("r.pcraft").path
        try first.saveDocument(to: path)
        let s = Session()
        _ = try s.openFile(path)
        let slot = s.saveSlot(try #require(s.active?.id))
        let opened = try #require(slot.opened)
        #expect(PcraftPreviews(stored: try PcraftFormat.readPreviews(contentsOf: opened.url), of: opened.document) != nil, "the file's previews can stand in")
        try s.execute("layer.select", ["layer": .id(try layer(s, "particles"))])
        try s.execute("select.rect", ["x": 600, "y": 600, "width": 50, "height": 50])
        try s.execute("edit.fill", ["color": "#ff00ff"])
        try s.execute("select.deselect")
        try s.saveDocument()
        #expect(slot.opened == nil)
        #expect(Self.levels(slot.last?.previews.options.composite, try Self.whole(s).composite) <= 1)
        #expect(Self.levels(slot.last?.previews.options.thumbnail, try Self.whole(s).thumbnail) <= 1)

        // Opened, then saved by someone else with a mark this session doesn't have: its previews
        // show that mark, so they aren't taken.
        let other = Session()
        _ = try other.openFile(path)
        let t = Session()
        _ = try t.openFile(path)
        try other.execute("layer.select", ["layer": .id(try layer(other, "particles"))])
        try other.execute("select.rect", ["x": 100, "y": 900, "width": 200, "height": 200])
        try other.execute("edit.fill", ["color": "#ffffff"])
        try other.execute("select.deselect")
        try other.saveDocument()
        try t.execute("layer.select", ["layer": .id(try layer(t, "particles"))])
        try t.execute("select.rect", ["x": 600, "y": 600, "width": 50, "height": 50])
        try t.execute("edit.fill", ["color": "#ff00ff"])
        try t.execute("select.deselect")
        try t.saveDocument()
        let ts = t.saveSlot(try #require(t.active?.id))
        #expect(Self.levels(ts.last?.previews.options.composite, try Self.whole(t).composite) <= 1)
    }

    /// A closed document's slot goes with it; a job finished after its document closed has no
    /// bookkeeping left to do.
    @Test func closingADocumentDropsItsSlot() throws {
        let dir = try ioDir("job-close")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try poster()
        let path = dir.appendingPathComponent("Poster.pcraft").path
        let job = try s.saveJob(to: path)
        let id = try #require(s.active?.id)
        #expect(s.state[SaveSlotsKey.self]?.byDocument[id.rawValue] != nil)
        s.close(try #require(s.activeIndex))
        #expect(s.state[SaveSlotsKey.self]?.byDocument[id.rawValue] == nil)
        let outcome = try s.finishSave(job, try job.run())
        #expect(try outcome.path == path && layers(path) == job.document.layers)
    }
}
