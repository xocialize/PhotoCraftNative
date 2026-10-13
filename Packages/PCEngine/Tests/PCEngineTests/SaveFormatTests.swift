// What File › Save writes (AB-D-0131, AB-T-0240): `.pcraft` packages by default, saved
// incrementally; single-file `.pcraft` stays single; PSD and PSB stay PSD and PSB, with warnings for
// what they can't keep.

import Foundation
@testable import PCEngine
import PCDocument
import PCFormat
import Testing

/// The local disk, but whole files only (as a capability-scoped automation file system is).
struct WholeFilesOnly: FileSystemService {
    let local = LocalFileSystem()
    func read(_ path: String) throws -> Data { try local.read(path) }
    func write(_ path: String, _ data: Data) throws { try local.write(path, data) }
    func exists(_ path: String) -> Bool { local.exists(path) }
    func isDirectory(_ path: String) -> Bool { local.isDirectory(path) }
}

@Suite struct SaveFormatTests {
    /// A two-layer document, 1024 × 512 (4 × 2 tiles), with ink in its first tile.
    func poster(_ s: Session = Session()) throws -> Session {
        try s.execute("file.new", ["width": 1024, "height": 512, "name": "Poster"])
        try s.execute("layer.new.layer", ["name": "Ink"])
        try s.execute("select.rect", ["x": 4, "y": 4, "width": 40, "height": 30])
        try s.execute("edit.fill", ["color": "#cc2244"])
        try s.execute("select.deselect")
        return s
    }

    func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    @Test func untitledDocumentsSaveAsAPcraftPackage() throws {
        let dir = try ioDir("untitled")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try poster()
        #expect(try s.savePlan() == SavePlan(format: .pcraftPackage, path: nil, proposedName: "Poster.pcraft"))
        #expect(throws: EngineError.self, "Save asks where") { try s.saveDocument() }
        let path = dir.appendingPathComponent("Poster.pcraft").path
        let r = try s.saveDocument(to: path)
        #expect(!r.copy && r.warnings.isEmpty)
        #expect(r.stats?.tilesWritten == r.stats?.tilesTotal)
        #expect(isDirectory(path) && PcraftFormat.container(at: URL(fileURLWithPath: path)) == .package)
        #expect(s.active?.path == path && s.active?.isDirty == false)
        #expect(try s.savePlan() == SavePlan(format: .pcraftPackage, path: path, proposedName: "Poster.pcraft"))
        // The package opens, under its file name.
        let (i, warnings, _) = try s.openFile(path)
        #expect(warnings.isEmpty)
        #expect(s.documents[i].doc.name == "Poster.pcraft")
        #expect(s.documents[i].doc.layers == s.documents[0].doc.layers)
    }

    /// Save writes only the tiles an edit changed, and Revert reads the package back.
    @Test func packageSavesWriteOnlyTheTilesThatChanged() throws {
        let dir = try ioDir("incremental")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try poster()
        let path = dir.appendingPathComponent("Poster.pcraft").path
        let first = try s.saveDocument(to: path)
        let saved = s.active!.doc
        #expect((first.stats?.tilesTotal ?? 0) >= 2)
        try s.execute("select.rect", ["x": 100, "y": 60, "width": 20, "height": 20])
        try s.execute("edit.fill", ["color": "#2244cc"])
        try s.execute("select.deselect")
        let r = try s.execute("file.save")
        #expect(r["path"]?.stringValue == path)
        #expect(r["tiles"]?["written"]?.intValue == 1, "\(r)")
        #expect(r["tiles"]?["reused"]?.intValue == (first.stats?.tilesTotal ?? 0) - 1)
        let edited = s.active!.doc
        #expect(edited.layers != saved.layers)
        #expect(try PcraftFormat.load(contentsOf: URL(fileURLWithPath: path)).layers == edited.layers)
        // Revert reloads the package.
        try s.execute("select.rect", ["x": 300, "y": 300, "width": 8, "height": 8])
        try s.execute("edit.fill", ["color": "#00ff00"])
        try s.execute("select.deselect")
        #expect(s.isEnabled("file.revert"), "\(s.disabledReason("file.revert") ?? "")")
        try s.execute("file.revert")
        #expect(s.active?.doc.layers == edited.layers)
        #expect(s.active?.isDirty == false)
    }

    @Test func aSingleFilePcraftStaysASingleFile() throws {
        let dir = try ioDir("single")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try poster()
        let path = dir.appendingPathComponent("Shared.pcraft").path
        let r = try s.execute("file.saveAs", ["path": .string(path), "form": "singleFile"])
        #expect(r["tiles"] == nil)
        #expect(!isDirectory(path) && PcraftFormat.container(at: URL(fileURLWithPath: path)) == .singleFile)
        #expect(try s.savePlan() == SavePlan(format: .pcraftSingleFile, path: path, proposedName: "Shared.pcraft"))
        try s.execute("layer.setProps", ["opacity": 0.5])
        try s.execute("file.save")
        #expect(!isDirectory(path))
        let s2 = Session()
        let (i, _, _) = try s2.openFile(path)
        #expect(s2.documents[i].doc.layers == s.active?.doc.layers)
        #expect(try s2.savePlan(i).format == .pcraftSingleFile)
        // The other form can't replace it under the same name, either way round.
        #expect(throws: EngineError.self) { try s.saveDocument(to: path, pcraftForm: .package) }
        let package = dir.appendingPathComponent("Package.pcraft").path
        try s.saveDocument(to: package)
        #expect(throws: EngineError.self) { try s.saveDocument(to: package, pcraftForm: .singleFile) }
        #expect(throws: EngineError.self) { try s.execute("file.saveAs", ["path": .string(path), "form": "zip"]) }
    }

    /// PSD stays PSD (and PSB stays PSB), with a warning for each thing it can't keep.
    @Test(arguments: ["psd", "psb"]) func aDocumentOpenedFromPhotoshopSavesBackToIt(_ ext: String) throws {
        let dir = try ioDir("photoshop-\(ext)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Layout.\(ext)").path
        try poster().saveDocument(to: path)
        let s = Session()
        try s.openFile(path)
        #expect(try s.savePlan() == SavePlan(format: ext == "psd" ? .psd : .psb, path: path, proposedName: "Layout.\(ext)"))
        try s.updateActive { $0.doc.timeline = Timeline(duration: 30, fps: 30) }
        let r = try s.saveDocument()
        #expect(r.path == path && !r.copy && r.stats == nil)
        #expect(r.warnings.contains { $0.contains("Timeline") && $0.contains(".pcraft") }, "\(r.warnings)")
        #expect(Array(try Data(contentsOf: URL(fileURLWithPath: path)).prefix(4)) == Array("8BPS".utf8))
    }

    /// A file Save doesn't write back to (a flat image, an import-only format) asks where, and
    /// proposes a `.pcraft` package named after it.
    @Test func flatSourcesProposeAPcraftPackage() throws {
        let dir = try ioDir("flat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("photo.png").path
        let one = Session()
        try one.execute("file.new", ["width": 64, "height": 48, "name": "photo"])
        try one.saveDocument(to: png)
        let s = Session()
        try s.openFile(png)
        #expect(try s.savePlan() == SavePlan(format: .pcraftPackage, path: nil, proposedName: "photo.pcraft"))
    }

    /// Readers of document bytes (Place, Open As, notes import) take a package as its single-file
    /// form, and a folder listing for batch commands offers packages but no other folder.
    @Test func packagesReadAsDocumentsEverywhere() throws {
        let dir = try ioDir("readers")
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("a.pcraft").path
        let s = try poster()
        try s.saveDocument(to: package)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try s.saveDocument(to: dir.appendingPathComponent("b.png").path, forceCopy: true)
        let bytes = try FileCommands.readFile(s, package)
        #expect(PcraftFormat.isPcraft(bytes))
        #expect(try PcraftFormat.load(bytes).layers == s.active?.doc.layers)
        #expect(try FileCommands.listImages(s, dir.path).map(DocState.fileName) == ["a.pcraft", "b.png"])
    }

    /// Without local folders, and in automation sessions, `.pcraft` saves are single files.
    @Test func singleFileSessionsAndFileSystems() throws {
        let dir = try ioDir("whole-files")
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = try poster()
        agent.newPcraftContainer = .singleFile
        #expect(try agent.savePlan().format == .pcraftSingleFile)
        let a = dir.appendingPathComponent("agent.pcraft").path
        try agent.saveDocument(to: a)
        #expect(!isDirectory(a))

        let s = try poster(Session(services: EngineServices(fileSystem: WholeFilesOnly())))
        let b = dir.appendingPathComponent("scoped.pcraft").path
        #expect(try s.pcraftContainer(for: b) == .singleFile)
        #expect(throws: EngineError.self) { try s.saveDocument(to: b, pcraftForm: .package) }
        try s.saveDocument(to: b)
        #expect(!isDirectory(b))
        // A package it finds can't be opened or saved without a local folder either.
        let c = dir.appendingPathComponent("package.pcraft").path
        try poster().saveDocument(to: c)
        #expect(throws: EngineError.self) { try s.openFile(c) }
        #expect(throws: EngineError.self) { try s.saveDocument(to: c) }
    }
}
