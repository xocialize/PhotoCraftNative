// Port of photocraft-engine (crates/engine/src/lib.rs `Session`, jobs.rs `dispatch`/`after_command`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The façade every frontend talks to (architecture §4.1): open documents, the active
// document/layer/selection targeting, history, background jobs, preferences, the command registry
// and the injected platform services. Every user-visible action is a command with a stable id and
// JSON params, run through `execute` / `start`: the app's menus and shortcuts, the command palette,
// actions, `pccli`, the JSON control channel and MCP all dispatch the same way.
//
// Concurrency: a `Session` is a reference type confined to one isolation domain — the app keeps it
// on the main actor, the automation server on its own serial executor, tests and the CLI on their
// thread — exactly as photocraft's `&mut Session`. Other threads read published `DocSnapshot`s
// (`snapshots`) and subscribe to `events()`; background work only ever sees snapshot values.

import Foundation
import PCDocument
import PCFormat
import PCFoundation
import PCHistory
import PCIntelligence
import PCPaint

public final class Session {
    /// Open documents, in tab order.
    public internal(set) var documents: [DocState] = []
    /// Index of the active document.
    public internal(set) var activeIndex: Int?
    /// App-wide tool state (colours, brush, presets).
    public var tools = ToolState()
    /// Executed journaled commands, oldest first (action recording, debugging).
    public var journal: [CommandInvocation] = []
    /// The command catalogue.
    public let registry: CommandRegistry
    /// Injected platform services.
    public let services: EngineServices
    /// Edit › Preferences.
    public var preferences: Preferences
    /// Module state (clipboards, panels' libraries, colour settings…).
    public var state = StateStore()
    /// Gate for every command the session runs, including the ones a command runs on its own
    /// behalf. Untrusted sessions (MCP, the control channel) install the same check a top-level
    /// request sees. nil runs everything (the app, `pccli run`).
    public var authorize: (@Sendable (String, JSONValue) throws -> Void)?
    /// Readers on other threads.
    public let snapshots = SnapshotStore()
    /// The form a save writes a new `.pcraft` file in (AB-D-0131): a document package, the app's
    /// default, or one file, which automation sessions use (scripts and agents expect one file).
    /// A file system without local folders (`FileSystemService.localURL`) always gets one file;
    /// an existing `.pcraft` keeps its form (`pcraftContainer(for:requested:)`).
    public var newPcraftContainer: PcraftFormat.Container = .package

    let hub = EventHub()
    var jobs = JobTable()
    /// Coalescing key of the command being executed.
    var coalesceRequest: String?
    /// Colour channel the running command may change (a single colour channel is targeted).
    public internal(set) var colorRestrict: Int?
    /// Depth of nested dispatches (a command running others on its behalf).
    var depth = 0

    public init(registry: CommandRegistry = .standard(), services: EngineServices = EngineServices(), preferences: Preferences = Preferences()) {
        ColorSetup.ensureInstalled()
        self.registry = registry
        self.services = services
        self.preferences = preferences
    }

    deinit {
        for j in jobs.running { j.ctx.cancel(); j.task?.cancel() }
        hub.finish()
    }

    /// The PCIntelligence service (provider registry for the AI commands).
    public var intelligence: PCIntelligence { services.intelligence }

    /// A new stream of session events.
    public func events() -> AsyncStream<SessionEvent> { hub.stream() }

    /// Sends an event to every subscriber.
    public func emit(_ e: SessionEvent) { hub.emit(e) }

    /// A status-bar message.
    public func toast(_ message: String) {
        hub.emit(.toast(message))
        services.notifier?(message)
    }

    // MARK: Documents

    /// The active document's state (a value copy).
    public var active: DocState? { activeIndex.flatMap { $0 < documents.count ? documents[$0] : nil } }

    /// Mutates the active document's state in place.
    @discardableResult
    public func updateActive<R>(_ body: (inout DocState) throws -> R) throws -> R {
        guard let i = activeIndex, i < documents.count else { throw EngineError.noDocument }
        return try body(&documents[i])
    }

    /// Mutates document `index`'s state in place.
    @discardableResult
    public func updateDocument<R>(at index: Int, _ body: (inout DocState) throws -> R) throws -> R {
        guard index >= 0, index < documents.count else { throw EngineError.other("no document at index \(index)") }
        return try body(&documents[index])
    }

    public func setActive(_ index: Int) -> Bool {
        guard index >= 0, index < documents.count else { return false }
        if activeIndex != index {
            activeIndex = index
            hub.emit(.activeDocumentChanged(documents[index].id))
        }
        syncToolsMaskTarget()
        publish()
        return true
    }

    /// Adds a document (File › New, an import…) and makes it active. Its identity is kept unless
    /// another open document already owns it. Returns its index.
    @discardableResult
    public func addDocument(_ doc: Document, path: String? = nil) -> Int {
        var doc = doc
        while documents.contains(where: { $0.id == doc.id }) { doc.id = .fresh() }
        let st = DocState(doc: doc, path: path, maxStates: preferences.historyStates, maxBytes: preferences.historyBudgetBytes)
        documents.append(st)
        let i = documents.count - 1
        activeIndex = i
        hub.emit(.documentOpened(doc.id, index: i))
        hub.emit(.activeDocumentChanged(doc.id))
        publish()
        return i
    }

    /// Closes document `index`; returns its state.
    @discardableResult
    public func close(_ index: Int) -> DocState? {
        guard index >= 0, index < documents.count else { return nil }
        let id = documents[index].id
        cancelJobs(on: id)
        for h in closeHooks { h(self, index) }
        discardRecovery(id)
        let d = documents.remove(at: index)
        if documents.isEmpty {
            activeIndex = nil
        } else if let a = activeIndex {
            activeIndex = a > index ? a - 1 : (a < index ? a : min(index, documents.count - 1))
        }
        hub.emit(.documentClosed(id))
        hub.emit(.activeDocumentChanged(active?.id))
        publish()
        return d
    }

    /// Moves document `from` to tab position `to`, keeping the active document active.
    public func moveDocument(from: Int, to: Int) -> Int? {
        guard from >= 0, from < documents.count else { return nil }
        let activeId = active?.id
        let d = documents.remove(at: from)
        let t = min(max(to, 0), documents.count)
        documents.insert(d, at: t)
        activeIndex = activeId.flatMap { id in documents.firstIndex { $0.id == id } }
        publish()
        return t
    }

    /// Index of the document with `id`.
    public func index(of id: DocId) -> Int? { documents.firstIndex { $0.id == id } }

    /// The active document's active layer (photocraft `active_layer_of`).
    public func activeLayer() -> Result<Layer, EngineError> {
        guard let d = active else { return .failure(.other("no document open")) }
        guard let id = d.activeLayer, let l = d.doc.layer(id) else { return .failure(.other("no active layer")) }
        return .success(l)
    }

    /// photocraft `layer_param`: the `"layer"` param, else the active layer.
    public func layerParam(_ p: JSONValue) throws -> LayerId {
        if let id = Params.layerId(p) { return id }
        guard let id = active?.activeLayer else { throw EngineError.other("no active layer") }
        return id
    }

    /// Makes `id` the active (and only selected) layer without a history step.
    public func selectLayer(_ id: LayerId) throws {
        try updateActive { st in
            guard st.doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            st.activeLayer = id
            st.selectedLayerIds = [id]
            st.layerAnchor = id
            Session.noEditRevision(&st)
        }
        runViewFixups()
        hub.emit(.layerTargetChanged(active!.id))
        publish()
    }

    /// Bumps the revision for a change that isn't an edit, keeping a clean document clean.
    static func noEditRevision(_ st: inout DocState) {
        let clean = st.savedRevision == st.revision
        st.revision += 1
        if clean { st.savedRevision = st.revision }
        st.lastDamage = .empty
    }

    func syncToolsMaskTarget() {
        let mask = maskTargetedHook?(self) ?? false
        tools.targetMask(mask)
    }

    /// Hooks a module installs on the session (mask targeting, document close).
    var maskTargetedHook: ((Session) -> Bool)? { registry.hooks.maskTargeted }
    var closeHooks: [@Sendable (Session, Int) -> Void] { registry.hooks.onClose }

    // MARK: Executing commands

    /// Runs a command by id with JSON params and returns its JSON result. Runs synchronously,
    /// including job-capable commands (`start` runs those in the background).
    ///
    /// Any command accepts `"coalesce": "<key>"`: consecutive edits with the same key (and no other
    /// edit, undo or redo in between) share one history step (one step per slider drag).
    @discardableResult
    public func execute(_ id: String, _ params: JSONValue = .object([:])) throws -> JSONValue {
        switch try dispatch(id, params, background: false) {
        case .done(let v): return v
        case .job(let j): return try waitJob(j)
        }
    }

    /// Runs a command given as an invocation.
    @discardableResult
    public func execute(_ inv: CommandInvocation) throws -> JSONValue { try execute(inv.id, inv.params) }

    /// Whether the command can run now (drives menu enablement).
    public func isEnabled(_ id: String, _ params: JSONValue = .null) -> Bool { disabledReason(id, params) == nil }

    /// Why the command can't run now (nil = it can): its own precondition, its availability, or a
    /// background job running on the active document.
    public func disabledReason(_ id: String, _ params: JSONValue = .null) -> String? {
        guard let spec = registry.spec(id) else { return "unknown command `\(id)`" }
        if let r = spec.availability.reason { return r }
        return precondition(spec, prepare(id, params)) ?? jobConflict(id, journal: spec.journal)
    }

    /// The `command.list` row of a command.
    public func listEntry(_ spec: CommandSpec) -> JSONValue {
        let reason = disabledReason(spec.id)
        let needsDocument = active == nil && (reason.map { r in ["no document", "no active document", "no open document"].contains { r.hasPrefix($0) } } ?? false)
        return [
            "id": .string(spec.id), "label": .string(spec.label), "menu": .strings(spec.menu),
            "shortcut": spec.shortcut.map(JSONValue.string) ?? .null, "params": .string(spec.params),
            "enabled": .bool(reason == nil), "disabledReason": reason.map(JSONValue.string) ?? .null,
            "needsDocument": .bool(needsDocument), "kind": .string(spec.kind.rawValue),
            "available": .bool(spec.isAvailable),
        ]
    }

    /// Params with the hooks' rewrites (Channels-panel target) applied.
    func prepare(_ id: String, _ params: JSONValue) -> JSONValue {
        var p = params == .null ? .object([:]) : params
        for h in registry.hooks.prepareParams { p = h(self, id, p) }
        return p
    }

    /// A command's precondition for a call (hooks first).
    func precondition(_ spec: CommandSpec, _ params: JSONValue) -> String? {
        if namesExistingLayer(spec.id, params) { return nil }
        for h in registry.hooks.enabledOverride {
            if let decided = h(self, spec.id, params) { return decided }
        }
        return spec.enabled(self, params)
    }

    /// Commands whose `"layer"` names an existing layer need no active layer (#2457).
    func namesExistingLayer(_ id: String, _ params: JSONValue) -> Bool {
        guard ["layer.hideLayers", "layer.showLayers", "layer.renameLayer"].contains(id), let l = Params.layerId(params) else { return false }
        return active?.doc.layer(l) != nil
    }

    /// The precondition of a command documenting `"layer":id`, checked on that layer when the
    /// params name an existing one (#466): a script can act on a layer without selecting it.
    func explicitLayerEnabled(_ spec: CommandSpec, _ params: JSONValue) -> Precondition? {
        guard spec.params.contains("\"layer\":id"), let target = Params.layerId(params), let i = activeIndex,
              documents[i].doc.layer(target) != nil else { return nil }
        let saved = documents[i].activeLayer
        documents[i].activeLayer = target
        let r = spec.enabled(self, params)
        documents[i].activeLayer = saved
        return .some(r)
    }

    /// Runs `id`: inline, or (with `background`) as a job when it is one.
    func dispatch(_ id: String, _ params: JSONValue, background: Bool) throws -> Started {
        guard let spec = registry.spec(id) else { throw EngineError.unknownCommand(id) }
        // Params are named fields: anything but an object (or null, meaning none) is a mistake.
        guard params == .null || params.objectValue != nil else { throw EngineError.bad(id, "params must be a JSON object") }
        let params = params == .null ? JSONValue.object([:]) : params
        if let gate = authorize { do { try gate(id, params) } catch { throw EngineError.wrap(error) } }
        if let reason = spec.availability.reason { throw EngineError.unavailable(id, reason) }
        // New Document's fields are checked before anything else happens (a floating selection
        // stays afloat when they are wrong).
        if id == "file.new" { try CoreCommands.validateNew(params) }
        for h in registry.hooks.before {
            if let v = try h(self, id, params) { return .done(v) }
        }
        let runParams = prepare(id, params)
        if let why = explicitLayerEnabled(spec, params) ?? precondition(spec, runParams) { throw EngineError.disabled(id, why) }
        if let why = jobConflict(id, journal: spec.journal) { throw EngineError.disabled(id, why) }
        for h in registry.hooks.refusal { if let why = h(self, id, params) { throw EngineError.other(why) } }
        let savedCoalesce = coalesceRequest, savedRestrict = colorRestrict, savedSpawn = jobs.spawn
        coalesceRequest = params["coalesce"]?.stringValue
        colorRestrict = registry.hooks.colorRestriction?(self, id, runParams)
        jobs.spawn = background
        let nestedFrom = journal.count
        depth += 1
        let r: Result<JSONValue, EngineError>
        do {
            // Paint commands convert their colours through the document's own CMYK profile.
            r = .success(try DocumentCMYK.scopes(id) ? DocumentCMYK.run(active?.doc) { try spec.run(self, runParams) } : spec.run(self, runParams))
        } catch { r = .failure(EngineError.wrap(error)) }
        depth -= 1
        jobs.spawn = savedSpawn
        coalesceRequest = savedCoalesce
        colorRestrict = savedRestrict
        let pending = jobs.pending
        jobs.pending = nil
        switch (r, pending) {
        case (.failure(let e), let job?):
            job.ctx.cancel()
            job.task?.cancel()
            throw e
        case (.failure(let e), nil):
            throw e
        case (.success, var job?):
            job.command = id
            job.params = params
            job.journal = spec.journal
            jobs.running.append(job)
            hub.emit(.jobStarted(job.id, command: id, label: job.label))
            publish()
            return .job(job.id)
        case (.success(let v), nil):
            afterCommand(id, params, journal: spec.journal, nestedFrom: nestedFrom)
            publish()
            hub.emit(.commandFinished(id: id, journal: spec.journal))
            return .done(v)
        }
    }

    /// Bookkeeping after a command (or a job's apply) succeeded. A replayable command stands for
    /// the commands it ran itself: their journal entries are dropped (#3067).
    func afterCommand(_ id: String, _ params: JSONValue, journal journaled: Bool, nestedFrom: Int?) {
        runViewFixups()
        for h in registry.hooks.after { h(self, id, params) }
        guard journaled else { return }
        if let from = nestedFrom, Session.replayable(id, registry: registry), from <= journal.count {
            journal.removeSubrange(from...)
        }
        if let c = registry.hooks.coalesceJournal, c(self, id, params) { return }
        journal.append(CommandInvocation(id, params))
    }

    /// photocraft `actions_cmds::replayable`.
    public static func replayable(_ id: String, registry: CommandRegistry) -> Bool {
        if id == "actions.play" { return true }
        if id.hasPrefix("actions.") || ["edit.transform.again", "edit.transform.againCopy", "file.scripts.browse"].contains(id) { return false }
        if ["view.fitOnScreen", "view.actualPixels", "view.zoomIn", "view.zoomOut", "file.save", "file.saveAs"].contains(id) { return true }
        return registry.spec(id)?.journal ?? false
    }

    /// Keeps view state consistent with the document (hooks such as the Channels panel's).
    func runViewFixups() {
        guard let i = activeIndex, i < documents.count else { return }
        for h in registry.hooks.viewFixups { h(self, &documents[i]) }
    }

    // MARK: Editing

    /// Applies an undoable edit to the active document: `body` edits a copy of the document and
    /// the active layer; the change is committed as one `EditTransaction` (one history step named
    /// `label`). When `body` throws, nothing changes.
    @discardableResult
    public func edit<R>(_ label: String, _ body: (inout Document, inout LayerId?) throws -> R) throws -> R {
        guard let i = activeIndex, i < documents.count else { throw EngineError.noDocument }
        let before = documents[i].doc
        var doc = before
        var activeLayer = documents[i].activeLayer
        let r: R
        do { r = try body(&doc, &activeLayer) } catch { throw EngineError.wrap(error) }
        finishEdit(index: i, label: label, before: before, after: doc, activeLayer: activeLayer, transaction: nil)
        return r
    }

    /// Commits a prebuilt transaction (a brush stroke, an AI operation, a rebased job) to the
    /// active document as one step; `active` (when given) becomes the active layer.
    public func commit(_ transaction: EditTransaction, active newActive: LayerId?? = nil) throws {
        guard let i = activeIndex, i < documents.count else { throw EngineError.noDocument }
        let before = documents[i].doc
        var doc = before
        do { _ = try transaction.apply(to: &doc) } catch { throw EngineError(error) }
        let a = newActive ?? documents[i].activeLayer
        finishEdit(index: i, label: transaction.label, before: before, after: doc, activeLayer: a, transaction: transaction)
    }

    func finishEdit(index i: Int, label: String, before: Document, after: Document, activeLayer: LayerId?, transaction: EditTransaction?) {
        var st = documents[i]
        let prior = st.layerTarget
        st.doc = after
        st.activeLayer = activeLayer
        for h in registry.hooks.afterEdit { h(self, &st, before) }
        st.fixSelection()
        // The hooks may have changed the document (colour-channel restriction): the transaction
        // is built from the final document unless the caller's still describes it.
        let t: EditTransaction
        if let transaction, st.doc == after { t = transaction } else { t = TransactionBuilder.transaction(label, from: before, to: st.doc) }
        let damage = TransactionBuilder.damage(t, before: before, after: st.doc)
        let layers = st.layerTarget
        let key = coalesceRequest
        if key == nil || st.coalesce != key || !st.history.canUndo {
            st.history.setCurrentLayers(prior)
            st.history.record(label, before: before, layers: layers)
            st.history.trim(st.doc)
        } else {
            st.history.setCurrentLayers(layers)
        }
        st.coalesce = key
        st.revision += 1
        st.lastDamage = damage
        st.lastTransaction = t
        documents[i] = st
        for h in registry.hooks.afterCommit { h(self, i, before) }
        hub.emit(.documentChanged(st.id, revision: st.revision, damage: damage))
    }

    /// Records the damage of the latest step more tightly than the transaction's (a command that
    /// knows exactly which pixels it changed).
    public func noteDamage(_ r: PixelRect?) {
        guard let i = activeIndex else { return }
        documents[i].lastDamage = r
    }

    // MARK: Undo / redo

    @discardableResult
    public func undo() -> Bool { step(redo: false) }

    @discardableResult
    public func redo() -> Bool { step(redo: true) }

    private func step(redo: Bool) -> Bool {
        // A background job is computing from the current state: it must not move under it.
        if activeJob != nil { return false }
        guard let i = activeIndex, i < documents.count else { return false }
        var st = documents[i]
        st.coalesce = nil
        let r = redo ? st.history.redo(st.doc) : st.history.undo(st.doc)
        guard let (d0, layers) = r else { return false }
        var d = d0
        // Save As changes file identity outside history.
        if d.name != st.doc.name { d.name = st.doc.name }
        let t = TransactionBuilder.transaction(redo ? "Redo" : "Undo", from: st.doc, to: d)
        let damage = TransactionBuilder.damage(t, before: st.doc, after: d, pixelExact: false)
        st.doc = d
        st.restoreTarget(layers)
        st.revision += 1
        st.lastDamage = damage
        st.lastTransaction = nil
        documents[i] = st
        runViewFixups()
        hub.emit(.documentChanged(st.id, revision: st.revision, damage: damage))
        publish()
        return true
    }

    // MARK: Snapshots

    /// Publishes the current state to `snapshots`.
    public func publish() { snapshots.publish(documents, active: activeIndex) }
}
