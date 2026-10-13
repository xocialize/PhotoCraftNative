// Port of photocraft-engine (crates/engine/src/jobs.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Background jobs: long commands run on a worker, report progress and can be cancelled (#210).
// A command opts in by doing its heavy work through `Session.runJob` (or `editJob` for a plain
// document edit, `runAsyncJob` for async work such as PCIntelligence's operations). The work gets a
// `JobContext` (progress plus a cancellation flag) and a snapshot — documents are values, so the
// copy is O(1) — and never sees the session. Its result is applied on the session's own thread as
// one undo step, through the same path as `execute`.
//
// * `execute` runs everything inline, as before (tests, the CLI, scripts see no difference).
// * `start` runs a job-capable command in the background and returns its `JobId`; `pollJobs`
//   applies finished jobs (the host calls it on `.jobReady`), `waitJob` blocks for one, and
//   `executeAsync` awaits one without blocking.
// * `cancelJob` sets the flag; the result is discarded and the document is unchanged.
// * While a job runs on a document, commands that would edit it are disabled with a message
//   naming the job.
// * Rebase (architecture §6): a job's result is a document edit computed from a snapshot. When the
//   document changed meanwhile (an edit that bypassed the lock), the edit's transaction is applied
//   to the current document instead — its ops address layers by id — or the job fails with a
//   conflict and nothing changes.

import Dispatch
import Foundation
import PCDocument
import PCHistory
import Synchronization

/// Identifies one background job for the session's lifetime.
public struct JobId: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "job \(rawValue)" }
}

/// Final state of a job.
public enum JobOutcome: Sendable, Equatable {
    /// Applied; the command's result.
    case done(JSONValue)
    /// Failed; the document is unchanged.
    case failed(String)
    /// Cancelled; the result (if any) was discarded and the document is unchanged.
    case cancelled
}

/// What a job's work sees: report progress, check for cancellation. Shared by reference; all
/// copies see the same state.
public final class JobContext: Sendable {
    private let cancelFlag = Atomic<Bool>(false)
    private let progressBits = Atomic<UInt32>(0)
    private let messageBox = Mutex<String>("")
    let id: JobId?
    let hub: EventHub?

    public init() { id = nil; hub = nil }
    init(id: JobId, hub: EventHub) { self.id = id; self.hub = hub }

    /// Reports progress in 0…1 with a short status (empty keeps the previous one). Progress never
    /// goes backwards.
    public func progress(_ fraction: Float, _ message: String = "") {
        if fraction.isFinite {
            let bits = min(max(fraction, 0), 1).bitPattern
            // Non-negative floats order like their bits.
            var cur = progressBits.load(ordering: .relaxed)
            while bits > cur {
                let (exchanged, now) = progressBits.compareExchange(expected: cur, desired: bits, ordering: .relaxed)
                if exchanged { break }
                cur = now
            }
        }
        if !message.isEmpty { messageBox.withLock { $0 = message } }
        if let id, let hub { hub.emit(.jobProgress(id, fraction: self.fraction, message: self.message)) }
    }

    public var isCancelled: Bool { cancelFlag.load(ordering: .relaxed) }

    /// Asks the job to stop (idempotent).
    public func cancel() { cancelFlag.store(true, ordering: .relaxed) }

    /// Throws `EngineError.cancelled` once cancelled, for `try` between stages.
    public func check() throws(EngineError) {
        if isCancelled { throw .cancelled }
    }

    public var fraction: Float { Float(bitPattern: progressBits.load(ordering: .relaxed)) }
    public var message: String { messageBox.withLock { $0 } }
}

/// A job's state for the UI, the control channel and MCP (`jobs.list`).
public struct JobInfo: Sendable, Equatable {
    public var id: JobId
    public var command: String
    public var label: String
    public var document: DocId?
    /// `running`, `done`, `failed` or `cancelled`.
    public var state: String
    public var progress: Float
    public var message: String
    public var elapsedMs: Double
    public var result: JSONValue?
    public var error: String?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .int(Int(id.rawValue)), "command": .string(command), "label": .string(label),
            "document": document.map { .int(Int($0.rawValue)) } ?? .null, "state": .string(state),
            "progress": .float(progress), "message": .string(message), "elapsedMs": .number(elapsedMs),
        ]
        if let result { o["result"] = result }
        if let error { o["error"] = .string(error) }
        return .object(o)
    }
}

/// How `Session.start` ended.
public enum Started: Sendable, Equatable {
    /// The command ran to completion inline.
    case done(JSONValue)
    /// The command is running in the background.
    case job(JobId)
}

/// A value crossing from a worker back to the session.
struct JobPayload: @unchecked Sendable {
    // Only Sendable values are ever stored (`runJob` requires `T: Sendable`).
    let value: Any
}

/// The completion of one job's work: blocking and async waiters.
final class JobCompletion: Sendable {
    private let state = Mutex<Result<JobPayload, EngineError>?>(nil)
    private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let semaphore = DispatchSemaphore(value: 0)

    func complete(_ r: Result<JobPayload, EngineError>) {
        let first = state.withLock { s -> Bool in
            if s != nil { return false }
            s = r
            return true
        }
        guard first else { return }
        semaphore.signal()
        let ws = waiters.withLock { w -> [CheckedContinuation<Void, Never>] in
            defer { w.removeAll() }
            return w
        }
        for c in ws { c.resume() }
    }

    var result: Result<JobPayload, EngineError>? { state.withLock { $0 } }

    /// Blocks until the work completes.
    func wait() -> Result<JobPayload, EngineError> {
        if let r = result { return r }
        semaphore.wait()
        semaphore.signal()
        return result ?? .failure(.other("job ended without a result"))
    }

    /// Suspends until the work completes.
    func value() async -> Result<JobPayload, EngineError> {
        if let r = result { return r }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let done = state.withLock { $0 != nil }
            if done { c.resume() } else {
                waiters.withLock { $0.append(c) }
                // Completed between the check and the append: resume now.
                if state.withLock({ $0 != nil }) {
                    let ws = waiters.withLock { w -> [CheckedContinuation<Void, Never>] in
                        defer { w.removeAll() }
                        return w
                    }
                    for w in ws { w.resume() }
                }
            }
        }
        return result ?? .failure(.other("job ended without a result"))
    }
}

/// One running job, as the session's table holds it.
struct RunningJob {
    let id: JobId
    var command: String
    let label: String
    var params: JSONValue
    var journal: Bool
    let doc: DocId?
    /// The document revision the work started from (nil: not tied to a document).
    let revision: UInt64?
    let ctx: JobContext
    let started: Date
    let coalesce: String?
    let colorRestrict: Int?
    let completion: JobCompletion
    var apply: ((Session, JobPayload, _ rebased: Bool) throws -> JSONValue)?
    var task: Task<Void, Never>?

    func info(state: String = "running") -> JobInfo {
        JobInfo(id: id, command: command, label: label, document: doc, state: state, progress: ctx.fraction, message: ctx.message,
                elapsedMs: Date().timeIntervalSince(started) * 1000, result: nil, error: nil)
    }
}

/// The session's job table.
struct JobTable {
    var next: UInt64 = 0
    /// Set while `start` runs a command: `runJob` spawns instead of running inline.
    var spawn = false
    /// The job a command registered while `spawn` was set.
    var pending: RunningJob?
    var running: [RunningJob] = []
    /// The last few ended jobs, for `jobs.list`.
    var recent: [JobInfo] = []
    /// The context inline job work runs under (a live preview another thread can cancel).
    var inline: JobContext?
    static let recentLimit = 16
}

/// What an `editJob`'s worker hands back.
struct EditJobOutput<R: Sendable>: Sendable {
    var doc: Document
    var active: LayerId?
    var result: R
    var transaction: EditTransaction
}

/// Run the inline (non-background) part of an async job synchronously.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = Mutex<Result<T, any Error>?>(nil)
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let r: Result<T, any Error>
        do { r = .success(try await work()) } catch { r = .failure(error) }
        box.withLock { $0 = r }
        sem.signal()
    }
    sem.wait()
    switch box.withLock({ $0 }) {
    case .success(let v): return v
    case .failure(let e): throw e
    case nil: throw EngineError.other("job ended without a result")
    }
}

extension Session {
    // MARK: Running work as a job

    /// Runs a job-capable command's heavy part. `work` runs on a worker when the command was
    /// started with `start` (inline otherwise); `apply` then runs on the session's thread with
    /// its output and returns the command's result. With `lockDocument`, the active document is
    /// locked against other edits while the job runs. `apply`'s `rebased` flag says the document
    /// changed since the work's snapshot (see the file comment).
    public func runJob<T: Sendable>(_ label: String, lockDocument: Bool,
                                    work: @escaping @Sendable (JobContext) throws -> T,
                                    apply: @escaping (Session, T, _ rebased: Bool) throws -> JSONValue) throws -> JSONValue {
        if !jobs.spawn {
            let t = try work(jobs.inline ?? JobContext())
            return try apply(self, t, false)
        }
        return try spawnJob(label, lockDocument: lockDocument, apply: apply) { ctx, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let r: Result<JobPayload, EngineError>
                do { r = .success(JobPayload(value: try work(ctx))) } catch { r = .failure(EngineError.wrap(error)) }
                completion.complete(r)
                if let id = ctx.id { ctx.hub?.emit(.jobReady(id)) }
            }
            return nil
        }
    }

    /// `runJob` for async work (PCIntelligence's operations, provider calls). Inline, it blocks
    /// the calling thread until the work is done.
    public func runAsyncJob<T: Sendable>(_ label: String, lockDocument: Bool,
                                         work: @escaping @Sendable (JobContext) async throws -> T,
                                         apply: @escaping (Session, T, _ rebased: Bool) throws -> JSONValue) throws -> JSONValue {
        if !jobs.spawn {
            let ctx = jobs.inline ?? JobContext()
            let t: T
            do { t = try runBlocking { try await work(ctx) } } catch { throw EngineError.wrap(error) }
            return try apply(self, t, false)
        }
        return try spawnJob(label, lockDocument: lockDocument, apply: apply) { ctx, completion in
            Task.detached(priority: .userInitiated) {
                let r: Result<JobPayload, EngineError>
                do { r = .success(JobPayload(value: try await work(ctx))) } catch { r = .failure(EngineError.wrap(error)) }
                completion.complete(r)
                if let id = ctx.id { ctx.hub?.emit(.jobReady(id)) }
            }
        }
    }

    private func spawnJob<T: Sendable>(_ label: String, lockDocument: Bool, apply: @escaping (Session, T, Bool) throws -> JSONValue,
                                       launch: (JobContext, JobCompletion) -> Task<Void, Never>?) throws -> JSONValue {
        if jobs.pending != nil { throw EngineError.other("`\(label)` started a second background job in one command") }
        var doc: DocId? = nil
        var revision: UInt64? = nil
        if lockDocument {
            guard let st = active else { throw EngineError.noDocument }
            doc = st.id
            revision = st.revision
        }
        jobs.next += 1
        let id = JobId(jobs.next)
        let ctx = JobContext(id: id, hub: hub)
        let completion = JobCompletion()
        let erased: (Session, JobPayload, Bool) throws -> JSONValue = { s, payload, rebased in
            guard let t = payload.value as? T else { throw EngineError.other("internal error: job result type mismatch") }
            return try apply(s, t, rebased)
        }
        var job = RunningJob(id: id, command: "", label: label, params: .null, journal: true, doc: doc, revision: revision, ctx: ctx,
                             started: Date(), coalesce: coalesceRequest, colorRestrict: colorRestrict, completion: completion, apply: erased)
        job.task = launch(ctx, completion)
        jobs.pending = job
        return ["job": .int(Int(id.rawValue))]
    }

    /// A document edit whose body is the job: like `edit` (one undo step named `label`), but
    /// `body` runs on a worker against a copy of the active document when started in the
    /// background. `finish` turns its output into the command's result.
    public func editJob<R: Sendable>(_ label: String,
                                     _ body: @escaping @Sendable (inout Document, inout LayerId?, JobContext) throws -> R,
                                     finish: @escaping @Sendable (R) -> JSONValue) throws -> JSONValue {
        if !jobs.spawn {
            let ctx = jobs.inline ?? JobContext()
            let r = try edit(label) { doc, active in try body(&doc, &active, ctx) }
            return finish(r)
        }
        guard let st = active else { throw EngineError.noDocument }
        let base = st.doc
        let active0 = st.activeLayer
        return try runJob(label, lockDocument: true, work: { ctx in
            var doc = base
            var a = active0
            let r = try body(&doc, &a, ctx)
            try ctx.check()
            // The transaction is computed on the worker, so a rebase only applies its ops.
            let t = TransactionBuilder.transaction(label, from: base, to: doc)
            return EditJobOutput(doc: doc, active: a, result: r, transaction: t)
        }, apply: { (s: Session, out: EditJobOutput<R>, rebased: Bool) in
            if rebased {
                try s.commit(out.transaction, active: out.active)
            } else {
                try s.edit(label) { d, a in
                    d = out.doc
                    a = out.active
                }
            }
            return finish(out.result)
        })
    }

    // MARK: Starting, polling, waiting

    /// Runs a command, in the background when it supports it. Errors like `execute` for unknown,
    /// disabled or failing commands.
    public func start(_ id: String, _ params: JSONValue = .object([:])) throws -> Started {
        try dispatch(id, params, background: true)
    }

    /// Applies finished background jobs and returns the jobs that ended since the last call.
    @discardableResult
    public func pollJobs() -> [(JobId, JobOutcome)] {
        var ended: [(JobId, JobOutcome)] = []
        var i = 0
        while i < jobs.running.count {
            if let r = jobs.running[i].completion.result {
                let job = jobs.running.remove(at: i)
                ended.append((job.id, finishJob(job, r)))
            } else {
                i += 1
            }
        }
        if !ended.isEmpty { publish() }
        return ended
    }

    /// Blocks until job `id` ends, applies it, and returns its result (the control channel's and
    /// MCP's default `wait`, and the CLI). Throws `cancelled` if it was cancelled.
    public func waitJob(_ id: JobId) throws -> JSONValue {
        if let i = jobs.running.firstIndex(where: { $0.id == id }) {
            let job = jobs.running.remove(at: i)
            let r = job.completion.wait()
            _ = finishJob(job, r)
            publish()
        }
        return try jobResult(id)
    }

    /// `waitJob` without blocking a thread.
    public nonisolated(nonsending) func awaitJob(_ id: JobId) async throws -> JSONValue {
        if let job = jobs.running.first(where: { $0.id == id }) {
            _ = await job.completion.value()
            if let i = jobs.running.firstIndex(where: { $0.id == id }), let r = jobs.running[i].completion.result {
                let j = jobs.running.remove(at: i)
                _ = finishJob(j, r)
                publish()
            }
        }
        return try jobResult(id)
    }

    /// Runs a command and waits for it without blocking a thread when it is a job.
    public nonisolated(nonsending) func executeAsync(_ id: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        switch try start(id, params) {
        case .done(let v): return v
        case .job(let j): return try await awaitJob(j)
        }
    }

    private func jobResult(_ id: JobId) throws -> JSONValue {
        guard let j = jobs.recent.last(where: { $0.id == id }) else { throw EngineError.other("no job \(id.rawValue)") }
        switch j.state {
        case "done": return j.result ?? .null
        case "cancelled": throw EngineError.cancelled
        default: throw EngineError.other(j.error ?? "the job failed")
        }
    }

    /// Cancels job `id`: it stops at its next check, its result is discarded and the document
    /// stays unchanged. False if no such job is running.
    @discardableResult
    public func cancelJob(_ id: JobId) -> Bool {
        guard let i = jobs.running.firstIndex(where: { $0.id == id }) else { return false }
        let job = jobs.running.remove(at: i)
        job.ctx.cancel()
        job.task?.cancel()
        endJob(job, .cancelled)
        return true
    }

    /// Cancels every running job.
    public func cancelAllJobs() {
        for id in jobs.running.map(\.id) { cancelJob(id) }
    }

    public var hasJobs: Bool { !jobs.running.isEmpty }

    /// Running jobs.
    public var runningJobs: [JobInfo] { jobs.running.map { $0.info() } }

    /// Running jobs followed by the last few that ended (newest last), for `jobs.list`.
    public var jobsWithRecent: [JobInfo] { runningJobs + jobs.recent }

    /// The running job that locks document `doc`.
    public func job(on doc: DocId) -> JobInfo? { jobs.running.first { $0.doc == doc }?.info() }

    /// The running job that locks the active document.
    public var activeJob: JobInfo? { active.flatMap { job(on: $0.id) } }

    /// Runs the heavy part of inline job commands under `ctx`, so another thread can cancel them
    /// (a live preview whose parameters changed). nil restores the default.
    public func setInlineJobContext(_ ctx: JobContext?) { jobs.inline = ctx }

    /// Why command `id` can't run now because of a background job (nil = no conflict).
    func jobConflict(_ id: String, journal: Bool) -> String? {
        if !journal || independentOfDocument(id) { return nil }
        guard let job = activeJob else { return nil }
        return "“\(job.label)” is still running on this document; wait for it to finish or cancel it (Esc)"
    }

    func independentOfDocument(_ id: String) -> Bool {
        let prefixes = ["jobs.", "tools.", "view.", "window.", "help.", "brush.presets.", "gradient.presets."]
        let ids: Set<String> = ["file.new", "file.close", "file.closeAll", "edit.preferences", "edit.colorSettings", "edit.keyboardShortcuts", "edit.menus"]
        if prefixes.contains(where: { id.hasPrefix($0) }) || ids.contains(id) { return true }
        return registry.hooks.documentIndependent.contains { $0(id) }
    }

    /// Cancels the jobs editing document `doc` (it is closing).
    func cancelJobs(on doc: DocId) {
        for id in jobs.running.filter({ $0.doc == doc }).map(\.id) { cancelJob(id) }
    }

    /// Applies (or reports the failure of) a job whose work delivered `r`.
    @discardableResult
    func finishJob(_ job: RunningJob, _ r: Result<JobPayload, EngineError>) -> JobOutcome {
        let outcome: JobOutcome
        switch r {
        case .failure(.cancelled): outcome = .cancelled
        case .failure(let e): outcome = .failed(e.description)
        case .success where job.ctx.isCancelled: outcome = .cancelled
        case .success(let payload):
            do { outcome = .done(try applyJob(job, payload)) } catch let e as EngineError {
                outcome = e == .cancelled ? .cancelled : .failed(e.description)
            } catch {
                outcome = .failed(EngineError.wrap(error).description)
            }
        }
        endJob(job, outcome)
        return outcome
    }

    private func applyJob(_ job: RunningJob, _ payload: JobPayload) throws -> JSONValue {
        let prevActive = activeIndex
        var target: Int? = nil
        var rebased = false
        if let d = job.doc {
            guard let i = documents.firstIndex(where: { $0.id == d }) else {
                throw EngineError.other("`\(job.label)`: the document was closed")
            }
            rebased = documents[i].revision != job.revision
            activeIndex = i
            target = i
        }
        coalesceRequest = job.coalesce
        colorRestrict = job.colorRestrict
        defer {
            coalesceRequest = nil
            colorRestrict = nil
        }
        guard let apply = job.apply else { throw EngineError.other("internal error: job applied twice") }
        let r: JSONValue
        do {
            r = try apply(self, payload, rebased)
        } catch {
            if target != nil, activeIndex == target { activeIndex = prevActive.flatMap { $0 < documents.count ? $0 : nil } ?? activeIndex }
            throw error
        }
        afterCommand(job.command, job.params, journal: job.journal, nestedFrom: nil)
        // Keep the user's active document unless the job opened a new one.
        if target != nil, activeIndex == target {
            activeIndex = prevActive.flatMap { $0 < documents.count ? $0 : nil } ?? activeIndex
        }
        return r
    }

    private func endJob(_ job: RunningJob, _ outcome: JobOutcome) {
        var info = job.info()
        switch outcome {
        case .done(let v):
            info.state = "done"
            info.result = v
            info.progress = 1
        case .failed(let e):
            info.state = "failed"
            info.error = e
        case .cancelled:
            info.state = "cancelled"
        }
        jobs.recent.append(info)
        if jobs.recent.count > JobTable.recentLimit { jobs.recent.removeFirst(jobs.recent.count - JobTable.recentLimit) }
        hub.emit(.jobEnded(job.id, outcome))
    }
}
