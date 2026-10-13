// Port of photocraft-automation's workspace tests (crates/automation/src/workspace.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: `open_pcraft_loads_a_directory_below_the_read_root` and
// `open_pcraft_rejects_non_regular_entries_and_escaping_symlinks` (they write and load `.pcraft`
// bundles: PCIO), the two Windows-only link tests. `open_pcraft_reports_zip_files_and_missing_paths_clearly`
// is adapted: a plain regular file stands in for the zip form PCIO would write.

import Darwin
import Foundation
@testable import PCAutomation
import PCDocument
import PCEngine
import PCFormat
import PCFoundation
import Testing

/// photocraft's `roots(name)`: an `inside` root (read and write) and an `outside` sibling.
func workspaceRoots(_ name: String) throws -> (inside: URL, outside: URL, workspace: AuthorizedWorkspace) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("photocraft-workspace-\(getpid())-\(name)-\(UUID().uuidString.prefix(8))")
    let inside = base.appendingPathComponent("inside"), outside = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    return (inside, outside, try AuthorizedWorkspace(readRoot: inside.path, writeRoot: inside.path))
}

func contents(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

/// A reader over `bytes` (Rust's `Cursor`).
func cursor(_ bytes: [UInt8]) -> (UnsafeMutableRawBufferPointer) throws -> Int {
    var offset = 0
    return { buffer in
        let n = min(buffer.count, bytes.count - offset)
        if n <= 0 { return 0 }
        bytes.withUnsafeBytes { src in buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset..<offset + n])) }
        offset += n
        return n
    }
}

@Suite struct WorkspaceTests {
    @Test func exportCleanupOwnsOnlyCreatedFilesEvenWhenDroppedUncommitted() throws {
        let (inside, _, workspace) = try workspaceRoots("export-cleanup")
        try FileManager.default.createDirectory(at: inside.appendingPathComponent("frames"), withIntermediateDirectories: false)
        try Data("old".utf8).write(to: inside.appendingPathComponent("frames/clip_0009.png"))
        do {
            let export = try workspace.exportSequence("frames")
            try export.write("clip_0000.png", Data("new".utf8))
            #expect(throws: EngineError.self) { try export.write("clip_0009.png", Data("overwrite".utf8)) }
            #expect(throws: EngineError.self) { try export.write("../escape.png", Data("escape".utf8)) }
            // Dropped without a commit (photocraft: a rendering panic unwinds through it).
        }
        #expect(contents(inside.appendingPathComponent("frames")) == ["clip_0009.png"])
        #expect(try Data(contentsOf: inside.appendingPathComponent("frames/clip_0009.png")) == Data("old".utf8))
        #expect(throws: EngineError.self) { try AuthorizedWorkspace().exportSequence("frames") }
        // A committed sequence keeps its files.
        let kept = try workspace.exportSequence("frames/kept")
        try kept.write("a.png", Data("a".utf8))
        kept.commit()
        #expect(contents(inside.appendingPathComponent("frames/kept")) == ["a.png"])
    }

    @Test func exportDirectorySymlinksCannotEscapeTheGrantedRoot() throws {
        let (inside, outside, workspace) = try workspaceRoots("export-symlink")
        try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent("escape"), withDestinationURL: outside)
        #expect(throws: EngineError.self) { try workspace.exportSequence("escape") }
        #expect(throws: EngineError.self) { try workspace.exportSequence("escape/deeper") }
        #expect(contents(outside).isEmpty)
    }

    @Test func validReadAndNonexistentOutputWriteStayInRoot() throws {
        let (inside, _, workspace) = try workspaceRoots("valid")
        try Data("canary".utf8).write(to: inside.appendingPathComponent("read.txt"))
        #expect(try workspace.read("read.txt") == Data("canary".utf8))
        try workspace.write("new-output.txt", Data("created".utf8))
        #expect(try Data(contentsOf: inside.appendingPathComponent("new-output.txt")) == Data("created".utf8))
    }

    @Test func largeObservedLengthDoesNotTriggerAFixedLimitOrUpfrontReservation() throws {
        #expect(try AuthorizedWorkspace.readToObservedLength(observedLength: (1 << 30) + 1, cursor(Array("psb".utf8))) == Array("psb".utf8))
    }

    @Test func readGrowthIsRejectedAtTheObservedLength() throws {
        do {
            _ = try AuthorizedWorkspace.readToObservedLength(observedLength: 64, cursor([UInt8](repeating: 0x78, count: 65)))
            Issue.record("growth accepted")
        } catch {
            #expect("\(error)".contains("grew beyond its observed length of 64 bytes"))
        }
        #expect(try AuthorizedWorkspace.readToObservedLength(observedLength: 64, cursor([UInt8](repeating: 0x78, count: 64))).count == 64)
        #expect(throws: EngineError.self) { try AuthorizedWorkspace.readToObservedLength(observedLength: 0, cursor([0x78])) }
    }

    @Test func openPcraftReportsRegularFilesAndMissingPathsClearly() throws {
        let (inside, _, workspace) = try workspaceRoots("pcraft-errors")
        try Data("zip".utf8).write(to: inside.appendingPathComponent("zipped.pcraft"))
        #expect(try workspace.openPcraft("zipped.pcraft") == nil, "a regular file falls back to the bytes path")
        do {
            _ = try workspace.openPcraft("missing.pcraft")
            Issue.record("missing path accepted")
        } catch {
            #expect("\(error)".contains("failed"), "a missing path propagates its io error: \(error)")
        }
        #expect(throws: EngineError.self) { try AuthorizedWorkspace().openPcraft("x.pcraft") }
        // An empty directory is not a bundle: a format error, not a crash.
        try FileManager.default.createDirectory(at: inside.appendingPathComponent("empty.pcraft"), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try workspace.openPcraft("empty.pcraft") }
        // photocraft `open_pcraft_loads_a_directory_below_the_read_root`.
        var doc = Document(name: "Native", size: PixelSize(width: 16, height: 12), mode: .rgb, depth: .u8)
        doc.layers = [.raster("Layer 1", format: doc.pixelFormat)]
        _ = try PcraftWriter().saveDir(doc, inside.appendingPathComponent("native.pcraft"))
        let loaded = try #require(try workspace.openPcraft("native.pcraft"))
        #expect(loaded.size == PixelSize(width: 16, height: 12))
    }

    @Test func writeReplacesAtomicallyAndLeavesNoTempFile() throws {
        let (inside, _, workspace) = try workspaceRoots("atomic")
        let tmps = { (dir: URL) in contents(dir).filter { $0.hasSuffix(".tmp") } }
        try FileManager.default.createDirectory(at: inside.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try workspace.write("sub/out.psd", Data("original".utf8))
        try workspace.write("sub/out.psd", Data("replacement".utf8))
        #expect(try Data(contentsOf: inside.appendingPathComponent("sub/out.psd")) == Data("replacement".utf8))
        #expect(tmps(inside.appendingPathComponent("sub")).isEmpty)
        // Renaming over a directory fails: nothing is left behind and the directory survives.
        try FileManager.default.createDirectory(at: inside.appendingPathComponent("adir"), withIntermediateDirectories: true)
        #expect(throws: EngineError.self) { try workspace.write("adir", Data("x".utf8)) }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: inside.appendingPathComponent("adir").path, isDirectory: &isDir) && isDir.boolValue)
        #expect(tmps(inside).isEmpty)
    }

    @Test func writeIntoReadOnlyFolderKeepsTheOriginal() throws {
        let (inside, _, workspace) = try workspaceRoots("readonly")
        let ro = inside.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: ro.appendingPathComponent("doc.psd"))
        chmod(ro.path, 0o555)
        defer { chmod(ro.path, 0o755) }
        let rootUser = FileManager.default.createFile(atPath: ro.appendingPathComponent("probe").path, contents: Data())
        if !rootUser {
            #expect(throws: EngineError.self) { try workspace.write("ro/doc.psd", Data("new".utf8)) }
            #expect(try Data(contentsOf: ro.appendingPathComponent("doc.psd")) == Data("original".utf8))
            #expect(contents(ro).filter { $0.hasSuffix(".tmp") }.isEmpty)
        }
    }

    @Test func rejectsAbsoluteTraversalMixedPrefixAndMalformedPathsWithoutTrapping() throws {
        let (_, _, workspace) = try workspaceRoots("reject")
        for path in ["", "/absolute", "../escape", "a/../escape", "a\\..\\escape", "a\\b", "C:/escape", "a//b", "./a", "name:stream", "NUL", "con.txt",
                     "folder/COM1.log"] {
            #expect(throws: EngineError.self, "read accepted \(path)") { try workspace.read(path) }
            #expect(throws: EngineError.self, "write accepted \(path)") { try workspace.write(path, Data("x".utf8)) }
        }
    }

    @Test func readAndWriteAuthorityAreSeparate() throws {
        let (inside, _, _) = try workspaceRoots("separate")
        try Data("canary".utf8).write(to: inside.appendingPathComponent("read.txt"))
        let readOnly = try AuthorizedWorkspace(readRoot: inside.path)
        #expect(try readOnly.read("read.txt") == Data("canary".utf8))
        #expect(throws: EngineError.self) { try readOnly.write("blocked.txt", Data("x".utf8)) }
        let writeOnly = try AuthorizedWorkspace(writeRoot: inside.path)
        #expect(throws: EngineError.self) { try writeOnly.read("read.txt") }
        try writeOnly.write("written.txt", Data("ok".utf8))
    }

    @Test func missingParentIsAStableErrorBeforeAnyFileIsCreated() throws {
        let (inside, _, workspace) = try workspaceRoots("missing-parent")
        do {
            try workspace.write("missing/output.txt", Data("x".utf8))
            Issue.record("write into a missing folder succeeded")
        } catch {
            #expect("\(error)".contains("automation write"), "\(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: inside.appendingPathComponent("missing").path))
    }

    @Test func symlinkEscapeIsRejected() throws {
        let (inside, outside, workspace) = try workspaceRoots("symlink")
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(throws: EngineError.self) { try workspace.read("link/secret.txt") }
        #expect(throws: EngineError.self) { try workspace.write("link/new.txt", Data("blocked".utf8)) }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
        // A link that stays inside the root is followed, as cap-std follows it.
        try FileManager.default.createDirectory(at: inside.appendingPathComponent("real"), withIntermediateDirectories: false)
        try Data("in".utf8).write(to: inside.appendingPathComponent("real/f.txt"))
        try FileManager.default.createSymbolicLink(atPath: inside.appendingPathComponent("alias").path, withDestinationPath: "real")
        #expect(try workspace.read("alias/f.txt") == Data("in".utf8))
    }

    @Test func filesystemCommandsFailClosed() throws {
        for id in ["file.open", "file.openAs", "file.save", "file.saveAs", "file.saveACopy", "file.export.saveForWebLegacy", "pattern.import",
                   "layer.smartObjects.exportContents", "layer.smartObjects.replaceContents", "layer.smartObjects.relinkToFile",
                   "layer.smartObjects.convertToLinked", "measurementLog.export", "layer.videoLayers.reloadFrame", "edit.colorSettings"] {
            #expect(throws: EngineError.self, "\(id)") { try AutomationPolicy.authorizeEngineCommand(id, .object([:])) }
        }
        try AutomationPolicy.authorizeEngineCommand("file.new", .object([:]))
        for id in ["layer.smartObjects.editContents", "layer.smartObjects.convertToLayers", "layer.smartObjects.saveContents"] {
            try AutomationPolicy.authorizeDesktopEngineCommand(id, ["layer": 19])
        }
        for id in ["layer.smartObjects.editContents", "layer.smartObjects.convertToLayers"] {
            #expect(throws: EngineError.self) { try AutomationPolicy.authorizeEngineCommand(id, ["path": "/outside/source.psb"]) }
        }
        // The UI-level examples in docs/control-protocol.md.
        for id in ["view.zoomIn", "window.theme.pro", "edit.search"] { try AutomationPolicy.authorizeDesktopEngineCommand(id, .object([:])) }
        try AutomationPolicy.authorizeEngineCommand("image.mode.cmyk", .object([:]))
        #expect(throws: EngineError.self) { try AutomationPolicy.authorizeDesktopEngineCommand("image.mode.cmyk", .object([:])) }
        #expect(throws: EngineError.self) { try AutomationPolicy.authorizeEngineCommand("image.mode.rgb", ["profile": "/outside/profile.icc"]) }
        try AutomationPolicy.authorizeEngineCommand("image.mode.rgb", ["profile": "srgb"])
        #expect(throws: EngineError.self) { try AutomationPolicy.authorizeEngineCommand("filter.distort.displace", ["mapPath": "outside.png"]) }
        #expect(throws: EngineError.self) { try AutomationPolicy.authorizeEngineCommand("layer.setAdjustment", ["file": "outside.cube"]) }
        #expect(throws: EngineError.self) {
            try AutomationPolicy.authorizeEngineCommand("prefs.set", ["path": "colorSettings.workingRgb", "value": "outside.icc"])
        }
        #expect(throws: EngineError.self) { try AutomationPolicy.authorizeEngineStep("file.open", .object([:])) }
        try AutomationPolicy.authorizeEngineStep("actions.play", .object([:]))
        // An allowed command can't reach a refused one by running it on its own behalf.
        let session = Session()
        try session.execute("file.new", ["width": 4, "height": 4])
        session.authorize = AutomationPolicy.authorizeDesktopEngineStep
        let params: JSONValue = ["to": "grayscale"]
        try AutomationPolicy.authorizeDesktopEngineCommand("file.automate.conditionalModeChange", params)
        #expect(throws: (any Error).self) { try session.execute("file.automate.conditionalModeChange", params) }
        #expect(session.active?.doc.mode == .rgb)
        #expect(throws: EngineError.self) { try AutomationPolicy.authorizeDesktopEngineStep("file.saveACopy", .object([:])) }
    }

    @Test func applyDataSetIsJudgedByTheValuesItApplies() throws {
        let h = Headless()
        try h.commandRun("file.new", ["width": 8, "height": 8])
        let layer = try #require(try h.commandRun("layer.new.layer", .object([:]))["layer"])
        let defs: JSONValue = [["name": "shown", "layer": layer, "type": "visibility"], ["name": "photo", "layer": layer, "type": "pixelReplacement"]]
        try h.commandRun("image.variables.define", ["defs": defs])
        let sets: JSONValue = ["dataSets": [
            ["name": "hidden", "values": [["variable": "shown", "kind": "visibility", "value": false]]],
            ["name": "swap", "values": [
                ["variable": "shown", "kind": "visibility", "value": false],
                ["variable": "photo", "kind": "pixels", "value": "/outside/photo.png"],
            ]],
        ]]
        try h.commandRun("image.variables.dataSets", sets)
        let visible = { h.session.active?.doc.layers.allSatisfy(\.visible) ?? false }
        do {
            try h.commandRun("image.applyDataSet", ["name": "swap"])
            Issue.record("a data set with an ambient path applied")
        } catch {
            #expect("\(error)".contains("ambient filesystem paths"), "\(error)")
        }
        #expect(visible(), "a refused data set applies none of its values")
        try h.commandRun("image.applyDataSet", ["name": "hidden"])
        #expect(!visible())
    }

    @Test func automationRejectsAmbientPathCommandsAndPreferences() throws {
        let refused: [(String, JSONValue)] = [
            ("brush.presets.importAbr", ["path": "/outside/set.abr"]), ("gradient.presets.importGrd", ["path": "/outside/set.grd"]),
            ("plugin.install", ["path": "/outside/plugin.wasm"]), ("plugin.reload", ["path": "/outside/plugins"]), ("plugin.reload", .object([:])),
            ("plugin.install", ["path": " "]), ("swatches.import", ["path": "/outside/set.aco"]), ("swatches.export", ["path": "/outside/set.ase"]),
        ]
        for (id, p) in refused {
            #expect(throws: EngineError.self, "\(id): \(p)") { try AutomationPolicy.authorizeEngineCommand(id, p) }
        }
        let allowed: [(String, JSONValue)] = [
            ("brush.presets.importAbr", ["data": "QUJD"]), ("gradient.presets.importGrd", ["data": "QUJD"]), ("plugin.install", ["data": "QUJD"]),
            ("swatches.import", ["data": "QUJD"]), ("swatches.export", ["format": "ase"]),
        ]
        for (id, p) in allowed { try AutomationPolicy.authorizeEngineCommand(id, p) }
        for path in ["", "colorSettings", "colorSettings.workingRgb", "scriptEvents", "scriptEvents.enabled", ".scriptEvents", ".scriptEvents.enabled",
                     "historyLog.filePath", ".historyLog.filePath", "plugIns.additionalPluginsFolder", "scratchDisks.disks", ".", "..historyLog.filePath"] {
            #expect(throws: EngineError.self, "\(path)") { try AutomationPolicy.authorizeEngineCommand("prefs.set", ["path": .string(path), "value": .object([:])]) }
        }
        #expect(throws: EngineError.self) {
            try AutomationPolicy.authorizeEngineCommand("prefs.set", ["values": ["interface.language": "fr", "historyLog.filePath": "/outside/log"]])
        }
        try AutomationPolicy.authorizeEngineCommand("prefs.set", ["path": "interface.language", "value": "fr"])
    }

    /// Registry descriptions that refer to document vector paths, not host files.
    static func documentsFilesystemPathParams(_ id: String, _ params: String) -> Bool {
        if ["prefs.get", "prefs.reset"].contains(id) { return false }
        let vectorPaths: Set<String> = [
            "filter.blurGallery.pathBlur", "filter.render.flame", "shape.create", "shape.edit", "shape.info", "shape.presets.list", "shape.presets.new",
            "path.list", "path.info", "path.set", "path.transform", "path.moveAnchors", "path.moveHandle", "path.bendSegment", "path.convertPoint",
            "path.addAnchor", "path.deleteAnchor", "path.clippingPath.set", "path.rename", "path.stroke", "select.toWorkPath", "layer.vectorMask.add",
            "layer.vectorMask.edit", "layer.vectorMask.info", "paint.symmetryFromPath", "edit.defineCustomShape", "layer.combineShapes.unite",
            "layer.combineShapes.subtractFrontShape", "layer.combineShapes.intersectShapeAreas", "layer.combineShapes.excludeOverlappingShapes",
            "layer.combineShapes.mergeShapeComponents",
        ]
        // New fill and adjustment layers take a vector path as their vector mask (#1419).
        if vectorPaths.contains(id) || id.hasPrefix("layer.newFillLayer.") || id.hasPrefix("layer.newAdjustmentLayer.") { return false }
        return params.lowercased().contains("path")
    }

    @Test func registryFilesystemPathParamsAreClassified() throws {
        let probe: JSONValue = [
            "path": "/outside/photocraft-probe", "file": "/outside/photocraft-probe.icc", "mapPath": "/outside/photocraft-probe.png",
            "profile": "/outside/photocraft-probe.icc", "workingRgb": "/outside/photocraft-probe.icc", "workingCmyk": "/outside/photocraft-probe.icc",
            "workingGray": "/outside/photocraft-probe.icc", "input": "/outside/photocraft-input", "output": "/outside/photocraft-output",
            "paths": ["/outside/photocraft-probe.psd"],
        ]
        let preferenceProbe: JSONValue = ["path": ".scriptEvents", "value": .object([:])]
        // Only photocraft's own ids: the native port's new commands (the AI tier) take no paths.
        let photocraft = Set(PhotocraftCatalog.commands.map(\.id))
        let unclassified = CommandRegistry.standard().specs
            .filter { photocraft.contains($0.id) && Self.documentsFilesystemPathParams($0.id, $0.params) }
            .filter { spec in (try? AutomationPolicy.authorizeEngineCommand(spec.id, spec.id == "prefs.set" ? preferenceProbe : probe)) != nil }
            .map(\.id)
        #expect(unclassified.isEmpty, "filesystem path parameters in the command registry need an automation policy: \(unclassified)")
    }

    @Test func wholePreferencesUpdateCannotEnableAutomationScriptEvents() throws {
        let h = Headless()
        #expect(throws: (any Error).self) {
            try h.commandRun("prefs.set", ["path": "", "value": ["scriptEvents": ["enabled": true, "bindings": [
                ["event": "newDocument", "steps": [["file.saveACopy", ["path": "/outside/canary.psd"]]]],
            ]]]])
        }
        let refused: [(String, JSONValue)] = [
            ("brush.presets.importAbr", ["path": "/outside/set.abr"]), ("gradient.presets.importGrd", ["path": "/outside/set.grd"]),
            ("plugin.install", ["path": "/outside/plugin.wasm"]), ("plugin.reload", ["path": "/outside/plugins"]),
            ("prefs.set", ["path": "historyLog.filePath", "value": "/outside/log"]),
            ("prefs.set", ["values": ["interface.language": "fr", "historyLog.filePath": "/outside/log"]]),
        ]
        for (id, p) in refused { #expect(throws: (any Error).self, "\(id)") { try h.commandRun(id, p) } }
        try h.commandRun("file.new", ["width": 5, "height": 5])
        // (photocraft also checks `file_menu.event_log` stays empty; the native engine has no
        // Script Events yet, so nothing can fire.)
    }

    /// #2176: an absolute path beneath the root names the same file as its relative path; every
    /// other absolute path is refused before any file effect.
    @Test func absolutePathsBeneathTheRootAreTranslatedAndOthersRefused() throws {
        let (inside, outside, workspace) = try workspaceRoots("absolute-paths")
        try workspace.write(inside.appendingPathComponent("a.bin").path, Data("one".utf8))
        #expect(try Data(contentsOf: inside.appendingPathComponent("a.bin")) == Data("one".utf8))
        #expect(try workspace.read(inside.appendingPathComponent("a.bin").path) == Data("one".utf8))
        try FileManager.default.createDirectory(at: inside.appendingPathComponent("sub"), withIntermediateDirectories: false)
        try workspace.write(inside.appendingPathComponent("sub").appendingPathComponent("b.bin").path, Data("two".utf8))
        #expect(try Data(contentsOf: inside.appendingPathComponent("sub/b.bin")) == Data("two".utf8))
        #expect(try workspace.read("sub/b.bin") == Data("two".utf8), "relative paths still work")
        func refused(_ path: String) {
            do {
                try workspace.write(path, Data("x".utf8))
                Issue.record("accepted \(path)")
            } catch {
                #expect("\(error)".contains("automation path rejected"), "\(path): \(error)")
            }
        }
        refused(outside.appendingPathComponent("escape.bin").path)
        refused(inside.path + "/../outside/traversal.bin")
        refused(inside.path)
        refused(inside.appendingPathComponent("CON").path)
        refused(inside.appendingPathComponent("a.bin").path + ":hidden")
        // A sibling whose name merely starts with the root's name is not beneath it.
        let sibling = inside.deletingLastPathComponent().appendingPathComponent("inside-sibling")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        refused(sibling.appendingPathComponent("lookalike.bin").path)
        refused(inside.path + "-sibling/lookalike.bin")
        // Climbing back out through a subdirectory is refused too.
        refused(inside.path + "/sub/../../outside/climb.bin")
        #expect(!FileManager.default.fileExists(atPath: sibling.appendingPathComponent("lookalike.bin").path))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("climb.bin").path))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.bin").path))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("traversal.bin").path))
        #expect(try Data(contentsOf: inside.appendingPathComponent("a.bin")) == Data("one".utf8))
    }

    /// Each authority is checked against its own root, and none granted refuses absolute paths.
    @Test func absolutePathsAreCheckedAgainstTheAuthoritysOwnRoot() throws {
        let (inside, outside, _) = try workspaceRoots("absolute-authority")
        let workspace = try AuthorizedWorkspace(readRoot: outside.path, writeRoot: inside.path)
        let target = inside.appendingPathComponent("written.bin").path
        try workspace.write(target, Data("w".utf8))
        #expect(throws: EngineError.self, "not under the read root") { try workspace.read(target) }
        #expect(throws: EngineError.self) { try AuthorizedWorkspace().read(target) }
    }
}
