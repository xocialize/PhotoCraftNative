// Port of photocraft-engine (crates/engine/src/actions_cmds.rs, and the recording pause of jobs.rs `dispatch`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Window › Actions, as engine commands (`actions.record` / `stop` / `play` / `list` / `get` /
// `delete` / `move` / `rename` / `toggle`). The list lives in session state so the panel, the CLI,
// the control channel and MCP share one copy. Recording copies replayable journal entries
// (commands whose spec is journaled, except action-editing commands and the already-expanded
// `edit.transform.again` / `againCopy`) into an action. A replayable command's journal entry
// replaces the entries of the commands it ran on its own behalf, so they are recorded once
// (#3067), and recording pauses while such a command runs. Playback runs the steps with
// `Session.execute` (so `Session.authorize` applies to every nested step) and stops at the first
// error, leaving one history step per step that ran. Steps switched off with `actions.toggle`
// are skipped by playback, Batch and droplets.

import Foundation
import PCDocument

public enum ActionsCommands: CommandModule {
    public static let name = "actions_cmds"
    static let m = name

    /// Prefix of the persisted shortcut override that plays a named action (`actions.play:<name>`).
    public static let playShortcutPrefix = "actions.play:"

    // MARK: Model

    /// One recorded action. `steps` is the `[[id, params], …]` shape `file.automate.batch` and
    /// droplets accept (that is also its JSON form).
    public struct Action: Hashable, Sendable, Codable {
        public var name: String
        public var steps: [CommandInvocation]
        /// Indices of steps excluded from playback (unchecked in the Actions panel).
        public var disabled: Set<Int>

        public init(_ name: String, _ steps: [CommandInvocation] = [], disabled: Set<Int> = []) {
            self.name = name
            self.steps = steps
            self.disabled = disabled
        }

        public func stepEnabled(_ step: Int) -> Bool { !disabled.contains(step) }

        /// The steps playback runs, with their indices in `steps`.
        public var enabledSteps: [(index: Int, step: CommandInvocation)] {
            steps.enumerated().filter { stepEnabled($0.offset) }.map { (index: $0.offset, step: $0.element) }
        }

        /// `disabled` as JSON (ascending, like photocraft's `BTreeSet`).
        public var disabledJSON: JSONValue { .array(disabled.sorted().map { .int($0) }) }

        enum CodingKeys: String, CodingKey { case name, steps, disabled }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            let raw = try c.decodeIfPresent([JSONValue].self, forKey: .steps) ?? []
            steps = try raw.map { v in
                guard let a = v.arrayValue, a.count == 2, let id = a[0].stringValue else {
                    throw DecodingError.dataCorruptedError(forKey: .steps, in: c, debugDescription: "a step is [id, params]")
                }
                return CommandInvocation(id, a[1])
            }
            disabled = Set(try c.decodeIfPresent([Int].self, forKey: .disabled) ?? [])
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(steps.map { JSONValue.array([.string($0.id), $0.params]) }, forKey: .steps)
            if !disabled.isEmpty { try c.encode(disabled.sorted(), forKey: .disabled) }
        }
    }

    /// On-disk form of `ActionState.list` (`actions.json` in the preset store).
    public struct ActionsFile: Hashable, Sendable, Codable {
        public var version: UInt32
        public var actions: [Action]
        public init(version: UInt32 = 1, actions: [Action]) { self.version = version; self.actions = actions }
    }

    /// The action being recorded: the journal length when recording (re)started, and its index.
    public struct Recording: Hashable, Sendable {
        public var from: Int
        public var index: Int
        public init(from: Int, index: Int) { self.from = from; self.index = index }
    }

    /// Actions list and the recording / playback flags. Only `list` is persisted.
    public struct ActionState: Hashable, Sendable {
        public var list: [Action] = []
        public var recording: Recording?
        /// Nesting depth of `actions.play`, bounded by the playback stack limit.
        public var playing = 0
        /// Active action names, for cycle detection in engine and desktop playback.
        public var playbackStack: [String] = []
        /// Bumped whenever `list` changes, so a preset store can skip unchanged writes.
        public var rev: UInt64 = 0

        public init(list: [Action] = []) { self.list = list }

        mutating func touch() { if rev < .max { rev += 1 } }
    }

    /// The session's actions (`s.state[ActionsCommands.ActionStateKey.self]`).
    public enum ActionStateKey: StateKey { public static let defaultValue = ActionState() }

    /// A recording paused while a replayable command runs (photocraft's dispatch takes
    /// `actions.recording` around the command body and puts it back afterwards).
    struct Paused: Sendable {
        /// `Session.depth` when the command was dispatched.
        var depth: Int
        var saved: Recording?
    }

    enum PausedKey: StateKey { static let defaultValue: [Paused] = [] }

    /// The session's actions, with any recording a finished command paused put back.
    public static func state(_ s: Session) -> ActionState {
        resumeFinished(s)
        return s.state[ActionStateKey.self]
    }

    // MARK: Registration

    public static func register(into r: inout CommandRegistry) {
        installHooks(&r)
        r.add(specs())
    }

    /// photocraft's dispatch pauses recording while a journaled replayable command runs, so an
    /// action it plays (a script step) doesn't flush the steps it ran so far into the recorded
    /// action, nor move the recording mark past the entries it is about to replace. The core has
    /// no hook around the command body, so the pause starts in a `before` hook and ends in an
    /// `after` hook — or, when the command failed, at the next dispatch (or `state(_:)` read):
    /// whatever was paused at a depth the session has since returned from is put back.
    static func installHooks(_ r: inout CommandRegistry) {
        r.hooks.before.append { s, id, _ in
            resumeFinished(s)
            if let spec = s.registry.spec(id), spec.journal, replayable(id, s) {
                s.state[PausedKey.self].append(Paused(depth: s.depth, saved: s.state[ActionStateKey.self].recording))
                s.state[ActionStateKey.self].recording = nil
            }
            return nil
        }
        r.hooks.after.append { s, _, _ in resumeFinished(s) }
    }

    static func resumeFinished(_ s: Session) {
        while let last = s.state[PausedKey.self].last, last.depth >= s.depth {
            s.state[PausedKey.self].removeLast()
            if s.state[ActionStateKey.self].recording == nil { s.state[ActionStateKey.self].recording = last.saved }
        }
    }

    // MARK: Helpers (public for the automation commands and the desktop shell)

    /// Replay commands and named action calls, excluding edits to the action definitions and the
    /// already-expanded Again wrapper (photocraft `replayable`).
    public static func replayable(_ id: String, _ s: Session) -> Bool { Session.replayable(id, registry: s.registry) }

    /// File › Save and Save As, recorded by the desktop shell once the save has a path (#2032).
    public static func shellSaveCommand(_ id: String) -> Bool { id == "file.save" || id == "file.saveAs" }

    /// View-only menu commands recorded by the desktop shell; Batch and droplets skip them.
    public static func shellViewCommand(_ id: String) -> Bool {
        ["view.fitOnScreen", "view.actualPixels", "view.zoomIn", "view.zoomOut"].contains(id)
    }

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    /// photocraft `num`: an integer, or a finite float rounded (saturating like `as i64`).
    static func num(_ v: JSONValue) -> Int? {
        guard case .number(let n) = v, n.isFinite else { return nil }
        let r = n.rounded()
        if r >= 9.223372036854775807e18 { return .max }
        if r <= -9.223372036854775808e18 { return .min }
        return Int(r)
    }

    /// A non-negative whole number (photocraft `as_u64` then `usize::try_from`).
    static func index(_ v: JSONValue?) -> Int? { v?.uint64Value.flatMap { Int(exactly: $0) } }

    static func resolve(_ list: [Action], _ p: JSONValue, _ cmd: String) throws -> Int {
        guard let v = p["action"] else { throw bad(cmd, #"needs "action" (a name or an index)"#) }
        if let i = num(v) {
            if i < 0 { throw bad(cmd, "action index is negative") }
            if i >= list.count { throw bad(cmd, "no action at index \(i)") }
            return i
        }
        switch v.stringValue {
        case let name? where !name.isEmpty:
            guard let i = list.firstIndex(where: { $0.name == name }) else { throw bad(cmd, "no action named `\(name)`") }
            return i
        case _?: throw bad(cmd, "action name is empty")
        case nil: throw bad(cmd, #""action" must be a name or an index"#)
        }
    }

    static func fromStep(_ p: JSONValue, _ len: Int) throws -> Int {
        guard let v = p["from"], v != .null else { return 0 }
        guard let i = num(v) else { throw bad("actions.play", #""from" must be a step index"#) }
        if i < 0 { throw bad("actions.play", #""from" is negative"#) }
        if i > len { throw bad("actions.play", #""from" \#(i) is past the last step (\#(len))"#) }
        return i
    }

    /// Shared validation for headless and shell playback. Does not start playback.
    public static func playbackPlan(_ s: Session, _ p: JSONValue) throws -> (Action, Int) {
        let st = state(s)
        if st.playing > 0 && st.playbackStack.isEmpty { throw bad("actions.play", "an action is already playing") }
        let idx = try resolve(st.list, p, "actions.play")
        guard idx < st.list.count else { throw bad("actions.play", "no such action") }
        let action = st.list[idx]
        if st.playbackStack.contains(action.name) || st.recording?.index == idx {
            throw bad("actions.play", "recursive action call to `\(action.name)`")
        }
        if st.playbackStack.count >= 16 { throw bad("actions.play", "action nesting exceeds 16 levels") }
        return (action, try fromStep(p, action.steps.count))
    }

    /// The actions that `steps` call through Play Action steps, followed transitively, in list
    /// order, so a droplet can run without the Actions panel that made it (#2794). Index
    /// references in `steps` and in the copies become names. A target that doesn't resolve is left
    /// alone: it fails at playback, as it would have before.
    public static func calledActions(_ list: [Action], _ steps: inout [CommandInvocation]) -> [Action] {
        func targets(_ steps: inout [CommandInvocation], _ depth: Int, _ queue: inout [(Int, Int)]) {
            for k in steps.indices where steps[k].id == "actions.play" {
                guard let i = try? resolve(list, steps[k].params, "actions.play") else { continue }
                if i < list.count, steps[k].params.objectValue != nil {
                    steps[k].params = steps[k].params.setting("action", .string(list[i].name))
                }
                queue.append((i, depth))
            }
        }
        var queue: [(Int, Int)] = []
        targets(&steps, 1, &queue)
        var found: [Int: Action] = [:]
        while let next = queue.popLast() {
            let (i, depth) = next
            // Playback stops at 16 levels, so deeper calls never run.
            if depth > 16 || found[i] != nil { continue }
            guard i < list.count else { continue }
            var action = list[i]
            targets(&action.steps, depth + 1, &queue)
            found[i] = action
        }
        return found.keys.sorted().compactMap { found[$0] }
    }

    /// Replayable journal entries not yet committed to action `action` while recording.
    public static func pendingSteps(_ s: Session, _ action: Int) -> [CommandInvocation] {
        let rec = s.state[ActionStateKey.self].recording
        let from = rec.flatMap { $0.index == action ? $0.from : nil } ?? s.journal.count
        guard from < s.journal.count else { return [] }
        return s.journal[from...].filter { replayable($0.id, s) }
    }

    static func flushRecording(_ s: Session) throws {
        guard let rec = s.state[ActionStateKey.self].recording else { return }
        let idx = rec.index
        guard idx < s.state[ActionStateKey.self].list.count else { throw bad("actions.stop", "the action being recorded no longer exists") }
        let steps = pendingSteps(s, idx)
        s.state[ActionStateKey.self].recording = Recording(from: s.journal.count, index: idx)
        if !steps.isEmpty {
            s.state[ActionStateKey.self].list[idx].steps.append(contentsOf: steps)
            s.state[ActionStateKey.self].touch()
        }
    }

    static func notPlaying(_ s: Session, _ cmd: String) throws {
        if state(s).playing > 0 { throw bad(cmd, "cannot edit actions during playback") }
    }

    /// Suspends recording while a called action executes: its commands stay in the journal for
    /// diagnostics, but the parent action records just the named call.
    public static func beginPlayback(_ s: Session, _ action: Action) throws -> Recording? {
        try flushRecording(s)
        let recording = s.state[ActionStateKey.self].recording
        s.state[ActionStateKey.self].recording = nil
        s.state[ActionStateKey.self].playing += 1
        s.state[ActionStateKey.self].playbackStack.append(action.name)
        return recording
    }

    public static func finishPlayback(_ s: Session, _ recording: Recording?, _ action: Action, _ from: Int) {
        if !s.state[ActionStateKey.self].playbackStack.isEmpty { s.state[ActionStateKey.self].playbackStack.removeLast() }
        s.state[ActionStateKey.self].playing = max(s.state[ActionStateKey.self].playing - 1, 0)
        if let rec = recording {
            s.state[ActionStateKey.self].recording = Recording(from: s.journal.count, index: rec.index)
            var params: JSONValue = ["action": .string(action.name)]
            if from > 0 { params = params.setting("from", .int(from)) }
            s.journal.append(CommandInvocation("actions.play", params))
        }
    }

    /// Nested playback returns a structured failure even though the command itself succeeded.
    /// Promote it to the caller's failed step so no later parent steps run after a child fails.
    public static func nestedFailure(_ id: String, _ value: JSONValue) -> String? {
        guard id == "actions.play", let failure = value["failed"] else { return nil }
        let step = (failure["step"]?.uint64Value ?? 0).addingReportingOverflow(1)
        return "action `\(value["action"]?.stringValue ?? "")` step \(step.overflow ? UInt64.max : step.partialValue) failed: \(failure["error"]?.stringValue ?? "unknown error")"
    }

    /// Follow a selected/recording row when a list item is moved.
    public static func movedIndex(_ index: Int, from: Int, to: Int) -> Int {
        if index == from { return to }
        if from < index && index <= to { return index - 1 }
        if to <= index && index < from { return index + 1 }
        return index
    }

    // MARK: Commands

    static func list(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let st = state(s)
        let actions: [JSONValue] = st.list.map { ["name": .string($0.name), "steps": .int($0.steps.count)] }
        let recording = st.recording.flatMap { r in r.index < st.list.count ? JSONValue.string(st.list[r.index].name) : nil } ?? .null
        return ["actions": .array(actions), "recording": recording]
    }

    static func get(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let st = state(s)
        let idx = try resolve(st.list, p, "actions.get")
        let action = st.list[idx]
        return ["name": .string(action.name), "steps": .array(action.steps.map { .array([.string($0.id), $0.params]) }), "disabled": action.disabledJSON]
    }

    static func record(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "actions.record"
        try notPlaying(s, cmd)
        var st = state(s)
        if st.recording != nil { throw bad(cmd, "already recording; stop first") }
        let idx: Int
        if p["action"] != nil {
            idx = try resolve(st.list, p, cmd)
        } else {
            let name: String
            switch p["name"] {
            case nil, .null?:
                var n = st.list.count + 1
                while st.list.contains(where: { $0.name == "Action \(n)" }) {
                    let (next, o) = n.addingReportingOverflow(1)
                    if o { throw bad(cmd, "cannot allocate a unique action name") }
                    n = next
                }
                name = "Action \(n)"
            case .string(let n)? where !n.isEmpty: name = n
            case .string?: throw bad(cmd, #""name" is empty"#)
            case _?: throw bad(cmd, #""name" must be a string"#)
            }
            if st.list.contains(where: { $0.name == name }) { throw bad(cmd, "an action with this name already exists") }
            st.list.append(Action(name))
            st.touch()
            idx = st.list.count - 1
        }
        st.recording = Recording(from: s.journal.count, index: idx)
        s.state[ActionStateKey.self] = st
        return ["action": .string(st.list[idx].name), "index": .int(idx)]
    }

    static func stop(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try notPlaying(s, "actions.stop")
        guard let rec = state(s).recording else { throw bad("actions.stop", "not recording") }
        try flushRecording(s)
        s.state[ActionStateKey.self].recording = nil
        let action = s.state[ActionStateKey.self].list[rec.index]
        return ["action": .string(action.name), "steps": .int(action.steps.count)]
    }

    static func runRecorded(_ s: Session, _ action: Action, from: Int) -> (ran: Int, failed: JSONValue?) {
        var ran = 0
        for (i, step) in action.enabledSteps where i >= from {
            func failure(_ error: String) -> JSONValue { ["step": .int(i), "id": .string(step.id), "error": .string(error)] }
            if let auth = s.authorize {
                do { try auth(step.id, step.params) } catch { return (ran, failure(EngineError.wrap(error).description)) }
            }
            do {
                let value = try s.execute(step.id, step.params)
                if let error = nestedFailure(step.id, value) { return (ran, failure(error)) }
                ran += 1
            } catch {
                return (ran, failure(EngineError.wrap(error).description))
            }
        }
        return (ran, nil)
    }

    static func play(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let (action, from) = try playbackPlan(s, p)
        let recording = try beginPlayback(s, action)
        let (ran, failed) = runRecorded(s, action, from: from)
        finishPlayback(s, recording, action, from)
        var out: JSONValue = ["action": .string(action.name), "ran": .int(ran)]
        if let failed { out = out.setting("failed", failed) }
        return out
    }

    /// Move to a final zero-based index, either in an action's steps or in the action list.
    static func moveItem(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "actions.move"
        try notPlaying(s, cmd)
        let st = state(s)
        let idx = try resolve(st.list, p, cmd)
        func idxParam(_ key: String) throws -> Int {
            guard let i = index(p[key]) else { throw bad(cmd, "\(key) must be a non-negative integer") }
            return i
        }
        let to = try idxParam("to")
        if p["step"] != nil {
            let step = try idxParam("step")
            let len = st.list[idx].steps.count + pendingSteps(s, idx).count
            if step >= len || to >= len { throw bad(cmd, "step or destination is out of range") }
            if st.recording?.index == idx { try flushRecording(s) }
            var action = s.state[ActionStateKey.self].list[idx]
            let moved = action.steps.remove(at: step)
            action.steps.insert(moved, at: to)
            action.disabled = Set(action.disabled.map { movedIndex($0, from: step, to: to) })
            s.state[ActionStateKey.self].list[idx] = action
            s.state[ActionStateKey.self].touch()
            return ["action": .string(action.name), "step": .int(to)]
        }
        if to >= st.list.count { throw bad(cmd, "destination is out of range") }
        var next = st
        let moved = next.list.remove(at: idx)
        next.list.insert(moved, at: to)
        if let r = next.recording { next.recording = Recording(from: r.from, index: movedIndex(r.index, from: idx, to: to)) }
        next.touch()
        s.state[ActionStateKey.self] = next
        return ["action": .string(moved.name), "index": .int(to)]
    }

    static func delete(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "actions.delete"
        try notPlaying(s, cmd)
        let st = state(s)
        let idx = try resolve(st.list, p, cmd)
        if let v = p["step"] {
            guard let step = index(v) else { throw bad(cmd, "step must be a non-negative integer") }
            let len = st.list[idx].steps.count + pendingSteps(s, idx).count
            if step >= len { throw bad(cmd, "step is out of range") }
            // Commit pending entries before editing the action; never erase the command journal
            // or undo the edit that produced the deleted recording step.
            if st.recording?.index == idx { try flushRecording(s) }
            var action = s.state[ActionStateKey.self].list[idx]
            action.steps.remove(at: step)
            action.disabled = Set(action.disabled.filter { $0 != step }.map { $0 > step ? $0 - 1 : $0 })
            s.state[ActionStateKey.self].list[idx] = action
            s.state[ActionStateKey.self].touch()
            return ["action": .string(action.name), "deletedStep": .int(step), "steps": .int(action.steps.count)]
        }
        if st.recording != nil { throw bad(cmd, "stop recording before deleting an action") }
        let name = s.state[ActionStateKey.self].list.remove(at: idx).name
        s.state[ActionStateKey.self].touch()
        return ["deleted": .string(name)]
    }

    /// The Actions panel check marks. With `step`, switch one step on or off; without it, switch
    /// every step (all on unless all already are, like clicking the action's check mark).
    static func toggle(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "actions.toggle"
        try notPlaying(s, cmd)
        let st = state(s)
        let idx = try resolve(st.list, p, cmd)
        let enabled: Bool?
        switch p["enabled"] {
        case nil, .null?: enabled = nil
        case .bool(let b)?: enabled = b
        case _?: throw bad(cmd, #""enabled" must be true or false"#)
        }
        let step: Int?
        switch p["step"] {
        case nil, .null?: step = nil
        case let v?:
            guard let i = index(v) else { throw bad(cmd, "step must be a non-negative integer") }
            step = i
        }
        let len = st.list[idx].steps.count + pendingSteps(s, idx).count
        if let step, step >= len { throw bad(cmd, "step is out of range") }
        if st.recording?.index == idx { try flushRecording(s) }
        var action = s.state[ActionStateKey.self].list[idx]
        if let step {
            if enabled ?? !action.stepEnabled(step) { action.disabled.remove(step) } else { action.disabled.insert(step) }
        } else if enabled ?? !action.disabled.isEmpty {
            action.disabled.removeAll()
        } else {
            action.disabled = Set(action.steps.indices)
        }
        s.state[ActionStateKey.self].list[idx] = action
        s.state[ActionStateKey.self].touch()
        return ["action": .string(action.name), "disabled": action.disabledJSON]
    }

    /// Rename an action in place. Nested `actions.play` steps that call it by name, and its
    /// function-key binding, follow the new name so nothing silently stops working.
    static func rename(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "actions.rename"
        try notPlaying(s, cmd)
        var st = state(s)
        let idx = try resolve(st.list, p, cmd)
        let name: String
        switch p["name"] {
        case .string(let n)? where !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: name = n
        case .string?: throw bad(cmd, #""name" is empty"#)
        case nil: throw bad(cmd, #"needs "name""#)
        case _?: throw bad(cmd, #""name" must be a string"#)
        }
        guard idx < st.list.count else { throw bad(cmd, "no such action") }
        let old = st.list[idx].name
        if old == name { return ["action": .string(name), "index": .int(idx)] }
        if st.list.contains(where: { $0.name == name }) { throw bad(cmd, "an action with this name already exists") }
        func follow(_ inv: inout CommandInvocation) {
            if inv.id == "actions.play", inv.params["action"]?.stringValue == old { inv.params = inv.params.setting("action", .string(name)) }
        }
        for a in st.list.indices { for k in st.list[a].steps.indices { follow(&st.list[a].steps[k]) } }
        let pending = st.recording?.from ?? s.journal.count
        if pending < s.journal.count { for k in pending..<s.journal.count { follow(&s.journal[k]) } }
        st.list[idx].name = name
        st.touch()
        s.state[ActionStateKey.self] = st
        // The action's function key follows the rename.
        let (from, to) = (playShortcutPrefix + old, playShortcutPrefix + name)
        if var shortcuts = s.preferences["shortcuts"]?.objectValue, let key = shortcuts[from] {
            shortcuts[from] = nil
            shortcuts[to] = key
            s.preferences = Preferences(values: s.preferences.values.setting("shortcuts", .object(shortcuts)))
            s.emit(.preferencesChanged)
        }
        return ["action": .string(name), "index": .int(idx)]
    }

    static func specs() -> [CommandSpec] {
        [
            CommandSpec("actions.move", "Move Action or Step",
                        params: #"{"action":name|index, "step":index?, "to":index}. Move a step within its action, or the action itself. to is the final zero-based index. Pending recorded steps can be moved."#,
                        module: m, journal: false, run: moveItem),
            CommandSpec("actions.list", "List Actions", params: #"{} → {actions:[{name, steps:count}], recording:name|null}"#,
                        module: m, journal: false, run: list),
            CommandSpec("actions.get", "Get Action",
                        params: #"{"action":name|index} → {name, steps:[[id, params]…], disabled:[step…]} (steps is the shape file.automate.batch and droplets take; disabled lists the 0-based steps playback skips)"#,
                        module: m, journal: false, run: get),
            CommandSpec("actions.record", "Record Action",
                        params: #"{"name":str? (new action, default "Action N")} or {"action":name|index} (append) → {action, index}"#,
                        module: m, journal: false, run: record),
            CommandSpec("actions.stop", "Stop Recording",
                        params: #"{} → {action, steps:count} (steps recorded since actions.record, queries and action-editing commands omitted)"#,
                        module: m, journal: false, run: stop),
            CommandSpec("actions.play", "Play Action",
                        params: #"{"action":name|index, "from":step?} → {action, ran, failed?:{step, id, error}}. step and from are 0-based; steps switched off with actions.toggle are skipped. Stops at the first error (the command still returns ok, with failed set) and leaves one history step per step that ran. Nested calls are supported up to 16 levels; cycles are rejected. Recording stores a named call rather than its expanded commands. Each step is checked with Session::authorize when one is installed."#,
                        module: m, journal: false, run: play),
            CommandSpec("actions.delete", "Delete Action",
                        params: #"{"action":name|index, "step":index?} → {deleted:name} or {action, deletedStep, steps:count}. step is 0-based, including pending recorded steps. Whole-action deletion is refused while recording."#,
                        module: m, journal: false, run: delete),
            CommandSpec("actions.toggle", "Toggle Action Steps",
                        params: #"{"action":name|index, "step":index?, "enabled":bool?} → {action, disabled:[step…]}. Switch one 0-based step (including pending recorded steps) on or off for playback, Batch and droplets; omitted enabled flips it. Without step, switch every step: on unless all already are, or as enabled says."#,
                        module: m, journal: false, run: toggle),
            CommandSpec("actions.rename", "Rename Action",
                        params: #"{"action":name|index, "name":str} → {action, index}. The name must not be empty or whitespace-only and must be unique. Nested Play Action steps and the action's function key follow the rename."#,
                        module: m, journal: false, run: rename),
        ]
    }
}
