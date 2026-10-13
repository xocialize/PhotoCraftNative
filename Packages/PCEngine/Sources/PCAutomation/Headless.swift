// Port of photocraft-automation (crates/automation/src/headless.rs `Headless`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// A headless editing session plus file I/O, shared by `pccli`, the JSON-lines control server and
// the MCP server. Untrusted sessions (control channel, MCP) gate every command — including the
// ones a command runs on its own behalf — with the automation policy, and reach files only
// through the launch-time roots; `trustedLocal` (the CLI naming its own paths) runs everything.

import Foundation
import PCDocument
import PCEngine
import PCFoundation

public final class Headless {
    /// Where file effects may go.
    public enum Filesystem: Sendable {
        /// Untrusted, no file access at all.
        case denied
        /// An explicit local CLI invocation: the caller names its own host paths.
        case trustedLocal
        /// Untrusted, confined to the launch-time roots.
        case workspace(AuthorizedWorkspace)
    }

    public let session: Session
    public let filesystem: Filesystem

    /// Transport limits (photocraft security.rs / budgets.rs), kept where the first port put them.
    public static let maxRequestBytes = ControlSecurity.maxRequestBytes
    public static let maxReplyBytes = Budgets.maxResponseBytes
    public static let maxBatchSteps = ControlSecurity.maxBatchSteps
    public static let maxPreviewSide = Budgets.maxPreviewSide
    public static let maxPreviewSourcePixels = Int(Budgets.maxRenderSourcePixels)
    public static let maxPreviewPNGBytes = Budgets.maxPNGBytes

    public init(filesystem: Filesystem, services: EngineServices? = nil) {
        self.filesystem = filesystem
        var svc = services ?? EngineServices()
        switch filesystem {
        case .denied: svc.fileSystem = DeniedFileSystem()
        case .trustedLocal: svc.fileSystem = LocalFileSystem()
        case .workspace(let w): svc.fileSystem = WorkspaceFileSystem(w)
        }
        session = Session(services: svc)
        if case .trustedLocal = filesystem {} else {
            // Every step of `actions.play` (and every command a command runs) is checked too.
            session.authorize = AutomationPolicy.authorizeEngineStep
        }
    }

    /// An automation session with no filesystem authority (photocraft `Headless::new`).
    public convenience init() { self.init(filesystem: .denied) }

    /// A session for an explicit local CLI invocation: the CLI caller, not a remote automation
    /// client, supplies these host paths. Nested `actions.play` steps are not re-checked.
    public static func trustedLocal() -> Headless { Headless(filesystem: .trustedLocal) }

    /// An automation session with capability-scoped file access.
    public static func withWorkspace(_ workspace: AuthorizedWorkspace) -> Headless { Headless(filesystem: .workspace(workspace)) }

    var trusted: Bool { if case .trustedLocal = filesystem { true } else { false } }

    /// Applies background jobs that finished since the last request, so every request (save,
    /// export, inspect, preview, `session.list`, commands) sees their result.
    public func syncJobs() { _ = session.pollJobs() }

    func docIndex(_ index: Int?) throws -> Int {
        if let i = index {
            guard i >= 0, i < session.documents.count else { throw AutomationError.badRequest("no document at index \(i)") }
            return i
        }
        guard let a = session.activeIndex else { throw AutomationError.badRequest("no document open") }
        return a
    }

    /// Makes document `index` (default: the active one) active for a method that acts on it.
    func activate(_ index: Int?) throws {
        let i = try docIndex(index)
        if session.activeIndex != i && !session.setActive(i) { throw AutomationError.badRequest("no document at index \(i)") }
    }

    func workspaceOrDenied(_ authority: String) throws -> AuthorizedWorkspace {
        guard case .workspace(let w) = filesystem else { throw AutomationError.absent(authority) }
        return w
    }

    // MARK: Documents

    /// Opens a file and makes it the active document.
    @discardableResult
    public func open(_ path: String) throws -> JSONValue {
        var o: FlatFiles.Opened
        switch filesystem {
        case .denied: throw AutomationError.absent("read")
        case .trustedLocal: o = try FlatFiles.open(path: path, services: session.services)
        case .workspace(let w):
            if let doc = try w.openPcraft(path) {
                o = FlatFiles.Opened(document: doc, warnings: [], sourceReadOnly: false)
            } else {
                let bytes = try w.read(path)
                let name = (path as NSString).lastPathComponent
                o = try FlatFiles.open(name: name.isEmpty ? path : name, data: bytes, services: session.services)
            }
        }
        var stored: String? = path
        if let untitled = FlatFiles.templateName(session, path) {
            o.document.name = untitled
            stored = nil
        }
        let index = session.addDocument(o.document, path: o.sourceReadOnly ? nil : stored)
        if o.sourceReadOnly { try? session.updateActive { $0.sourceReadOnly = true } }
        let d = session.documents[index].doc
        return [
            "index": .int(index), "name": .string(d.name), "width": .int(d.size.width), "height": .int(d.size.height),
            "layers": .int(d.layerCount), "warnings": .strings(o.warnings + FlatFiles.missingFontWarnings(d)),
        ]
    }

    /// Places a file into a document as a Smart Object layer: the capability-scoped counterpart
    /// of `file.placeEmbedded` (#2810). `path` resolves beneath the read root the way `open`
    /// resolves one; `params` carries the command's own options (`scale`, `fit`, `center`).
    public func place(index: Int?, path: String, params: JSONValue) throws -> JSONValue {
        try activate(index)
        let opts = JSONValue.object(params.members.merging(["path": .string(path)]) { _, new in new })
        if trusted { return try commandRun("file.placeEmbedded", opts) }
        let w = try workspaceOrDenied("read")
        let bytes = try w.read(path)
        let name = (path as NSString).lastPathComponent
        syncJobs()
        // The bytes are already in memory and the path resolved beneath the root capability, so
        // placing them needs no filesystem check of its own (`placeBytes` is the command body).
        return try FileCommands.placeBytes(session, name: name.isEmpty ? path : name, bytes: [UInt8](bytes), linked: nil, opts)
    }

    /// Exports each exported layer as its own file beneath the write root: the capability-scoped
    /// `file.export.layersToFiles` (#3216).
    public func exportLayers(index: Int?, dir: String, params: JSONValue) throws -> JSONValue {
        try activate(index)
        if trusted {
            return try commandRun("file.export.layersToFiles", .object(params.members.merging(["dir": .string(dir)]) { _, new in new }))
        }
        syncJobs()
        let outputs = try workspaceOrDenied("write").exportSequence(dir)
        return try exported(dir, outputs) {
            try FileCommands.exportLayersWith(session, params) { name, bytes in try outputs.write(name, Data(bytes)) }
        }
    }

    /// Commits an export sequence when the export succeeded, and removes what it wrote when it
    /// failed (photocraft `exported`).
    func exported(_ dir: String, _ outputs: ExportSequence, _ body: () throws -> [String]) throws -> JSONValue {
        do {
            let names = try body()
            outputs.commit()
            let files = names.map { "\(dir)/\($0)" }
            return ["files": .strings(files), "count": .int(files.count)]
        } catch {
            try outputs.cleanup()
            throw error
        }
    }

    /// Exports each data set as its own flattened file beneath the write root: the
    /// capability-scoped `file.export.dataSetsAsFiles` (#3216).
    public func exportDataSets(index: Int?, dir: String, params: JSONValue) throws -> JSONValue {
        try activate(index)
        if trusted {
            return try commandRun("file.export.dataSetsAsFiles", .object(params.members.merging(["dir": .string(dir)]) { _, new in new }))
        }
        syncJobs()
        let outputs = try workspaceOrDenied("write").exportSequence(dir)
        return try exported(dir, outputs) {
            try VariablesCommands.exportDataSets(session, params) { name, bytes in try outputs.write(name, Data(bytes)) }
        }
    }

    /// Imports a data-set CSV from the read root: the capability-scoped
    /// `file.import.variableDataSets` (#3216). The file is read beneath the root and must be
    /// UTF-8; the command's own parser then imports it.
    public func importDataSets(index: Int?, path: String, params: JSONValue) throws -> JSONValue {
        try activate(index)
        let opts = JSONValue.object(params.members.merging(["path": .string(path)]) { _, new in new })
        if trusted { return try commandRun("file.import.variableDataSets", opts) }
        let w = try workspaceOrDenied("read")
        let bytes = try w.read(path)
        guard let text = String(validating: [UInt8](bytes), as: UTF8.self) else {
            throw AutomationError.badRequest("automation read `\(path)` is not valid UTF-8: \(Self.utf8ErrorDescription(bytes))")
        }
        syncJobs()
        return try VariableDataSets.importText(session, text, params)
    }

    /// `FromUtf8Error`'s text: where the first invalid sequence starts.
    static func utf8ErrorDescription(_ bytes: Data) -> String {
        let b = [UInt8](bytes)
        var i = 0
        while i < b.count {
            let lead = b[i]
            let len = lead < 0x80 ? 1 : lead >> 5 == 0b110 ? 2 : lead >> 4 == 0b1110 ? 3 : lead >> 3 == 0b11110 ? 4 : 0
            if len == 0 || i + len > b.count || String(validating: b[i..<i + len], as: UTF8.self) == nil {
                return "invalid utf-8 sequence of 1 bytes from index \(i)"
            }
            i += len
        }
        return "invalid utf-8"
    }

    /// Saves (exports by extension). With no path, saves to the document's own path — only a
    /// layered file, in its own format (#416).
    @discardableResult
    public func save(index: Int?, path: String?, format: String?, options: FlatFiles.ExportOptions = .init()) throws -> JSONValue {
        let i = try docIndex(index)
        let storedPath = session.documents[i].path
        let doc = session.documents[i].doc
        let target: String
        if let path {
            target = path
        } else if let p = storedPath {
            let own = FlatFiles.extensionOf(path: p)
            let written = format.map { String($0.drop(while: { $0 == "." })).lowercased() } ?? own
            if !FlatFiles.savesInPlace(p) || written != own {
                throw AutomationError.badRequest(
                    "pass `path`: without one, only a PSD, PSB or .pcraft file is written back, in its own format, so `\(p)` was left unchanged")
            }
            target = p
        } else {
            throw AutomationError.badRequest("document has no path; pass `path`")
        }
        var warnings: [String]
        switch filesystem {
        case .denied: throw AutomationError.absent("write")
        case .trustedLocal:
            warnings = try FlatFiles.save(doc, path: target, format: format, options: options, renderer: session.services.renderer)
        case .workspace(let w):
            let (bytes, ws) = try FlatFiles.encode(doc, name: target, format: format, options: options, renderer: session.services.renderer)
            try w.write(target, bytes)
            warnings = ws
        }
        warnings += FlatFiles.missingFontWarnings(doc)
        // A layered save is a full write, not a flattened copy: it records the revision as saved
        // and makes the file the document's path. A flat export is a copy (#1547).
        let ext = format.map { String($0.drop(while: { $0 == "." })).lowercased() } ?? FlatFiles.extensionOf(path: target)
        if let ext, FlatFiles.layeredExtension(ext) {
            // Saving by index must not retarget the next automation command.
            let previous = session.activeIndex
            _ = session.setActive(i)
            try? session.updateActive { $0.savedTo(target) }
            if let previous { _ = session.setActive(previous) }
        }
        return ["path": .string(target), "warnings": .strings(warnings)]
    }

    /// The first port's spelling of `save`.
    @discardableResult
    public func save(index: Int?, path: String?, format: String?, quality: Int?) throws -> JSONValue {
        try save(index: index, path: path, format: format, options: .init(quality: quality))
    }

    /// Writes rendered bytes through the configured write authority.
    public func writeRender(_ path: String, _ bytes: Data) throws {
        switch filesystem {
        case .denied: throw AutomationError.absent("write")
        case .trustedLocal: try FlatFiles.atomicWrite(path, bytes)
        case .workspace(let w): try w.write(path, bytes)
        }
    }

    public func inspect(_ index: Int?) throws -> JSONValue {
        Inspect.document(session.documents[try docIndex(index)], registry: session.registry)
    }

    /// A flattened PNG preview; untrusted sessions are held to the preview budgets.
    public func renderPNG(_ index: Int?, maxSide: Int) throws -> Data {
        let doc = session.documents[try docIndex(index)].doc
        if !trusted { try Budgets.checkPreview(width: doc.size.width, height: doc.size.height, maxSide: maxSide) }
        let png = try FlatFiles.renderPNG(doc, maxSide: maxSide, renderer: session.services.renderer)
        if !trusted { try Budgets.checkPNG(png.count) }
        return png
    }

    public func sessionList() -> JSONValue { Inspect.session(session) }

    public func select(_ index: Int) throws -> JSONValue {
        guard session.setActive(index) else { throw AutomationError.badRequest("no document at index \(index)") }
        return sessionList()
    }

    public func close(_ index: Int?) throws -> JSONValue {
        session.close(try docIndex(index))
        return sessionList()
    }

    // MARK: Commands

    /// Every command's `command.list` row (photocraft `command_list`).
    public func commandList() -> JSONValue { .array(session.registry.specs.map { session.listEntry($0) }) }

    /// `commandList`, filtered by id/label text and, optionally, to commands that can run now.
    public func commandList(filter: String?, enabledOnly: Bool = false) -> JSONValue {
        let needle = filter?.lowercased()
        return .array(session.registry.specs.compactMap { spec in
            if let n = needle, !"\(spec.id) \(spec.label)".lowercased().contains(n) { return nil }
            let e = session.listEntry(spec)
            if enabledOnly && e["enabled"]?.boolValue == false { return nil }
            return e
        })
    }

    /// Runs a command and waits for its result.
    @discardableResult
    public func commandRun(_ id: String, _ params: JSONValue = .object([:]), wait: Bool = true) throws -> JSONValue {
        try commandStart(id, params, wait: wait)
    }

    /// Runs a command; with `wait` false a job-capable command (filters, Content-Aware Fill,
    /// Photomerge, …) runs in the background and this returns `{job, pending: true}` at once.
    /// Other commands finish before returning either way.
    @discardableResult
    public func commandStart(_ id: String, _ params: JSONValue, wait: Bool) throws -> JSONValue {
        let p = params == .null ? JSONValue.object([:]) : params
        if !trusted {
            if id == "file.export.renderVideo" { return try renderVideo(p) { _, _ in true } }
            try AutomationPolicy.authorizeEngineCommand(id, p)
        }
        // Background jobs that finished since the last request (or batch step) apply first.
        syncJobs()
        if wait { return try session.execute(id, p) }
        switch try session.start(id, p) {
        case .done(let v): return v
        case .job(let j): return ["job": .int(Int(j.rawValue)), "pending": true]
        }
    }

    /// A direct automation Render Video uses only the launch-time write capability; nested engine
    /// actions still refuse the filesystem command. `progress(done, total)` hears of each frame;
    /// returning false stops at a frame boundary, and a stopped or failed render removes the
    /// frames it wrote (photocraft `render_video`).
    func renderVideo(_ params: JSONValue, progress: (Int, Int) -> Bool) throws -> JSONValue {
        syncJobs()
        let w = try workspaceOrDenied("write")
        guard let dir = params["dir"]?.stringValue else { throw AutomationError.badRequest("renderVideo needs `dir`") }
        let outputs = try w.exportSequence(dir)
        do {
            let r = try VideoCommands.renderVideoWith(session, params, write: { name, bytes in try outputs.write(name, Data(bytes)) }, progress: progress)
            outputs.commit()
            return r
        } catch {
            try outputs.cleanup()
            throw error
        }
    }
}
