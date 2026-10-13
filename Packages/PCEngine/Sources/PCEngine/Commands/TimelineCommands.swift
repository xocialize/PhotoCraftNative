// Port of photocraft-engine (crates/engine/src/timeline_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Window › Timeline: create and drive the document timeline (playhead over N frames at a frame
// rate). Navigation doesn't add history steps. Video layers read `current` to show their frame
// (`VideoCommands.sync`). Headless and scriptable so agents can render frame ranges.

import Foundation
import PCDocument

enum TimelineCommands: CommandModule {
    static let name = "timeline_cmds"
    static let m = name

    /// Longest timeline, in frames: every frame becomes a surface in a new video layer and a file
    /// in Render Video, so `duration` is capped well before it can exhaust memory (#1009).
    static let maxDuration = 1_000_000
    /// Highest frame rate; larger values only come from mistakes (#1009).
    static let maxFPS: Float = 1000

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document" : nil }

    static let hasTimeline: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document" }
        return d.doc.timeline == nil ? "no timeline (create one first)" : nil
    }

    /// Mutates the document timeline without a history step (navigation / metadata).
    static func withTimeline(_ s: Session, _ f: (inout Timeline?) -> Void) throws -> JSONValue {
        let rev = try s.updateActive { st -> UInt64 in
            var doc = st.doc
            VideoCommands.store(&doc)
            f(&doc.timeline)
            doc.timeline?.clamp()
            VideoCommands.sync(&doc)
            st.doc = doc
            st.revision += 1
            // Every video layer may show another frame: no transaction, everything to redraw.
            st.lastDamage = nil
            st.lastTransaction = nil
            return st.revision
        }
        if let id = s.active?.id { s.emit(.documentChanged(id, revision: rev, damage: nil)) }
        return try info(s)
    }

    /// The optional `duration` param, rejected unless it's a whole number in `1...maxDuration`.
    static func durationParam(_ cmd: String, _ p: JSONValue) throws -> Int? {
        guard let v = p["duration"], v != .null else { return nil }
        guard let d = v.uint64Value, d >= 1, d <= UInt64(maxDuration) else {
            throw EngineError.bad(cmd, "`duration` must be a whole number of frames from 1 to \(maxDuration), got \(v.serialized())")
        }
        return Int(d)
    }

    /// The optional `fps` param, rejected unless it's a finite number in `(0, maxFPS]` (#1009).
    static func fpsParam(_ cmd: String, _ p: JSONValue) throws -> Float? {
        guard let v = p["fps"], v != .null else { return nil }
        guard let f = v.doubleValue, f.isFinite, f > 0, f <= Double(maxFPS) else {
            throw EngineError.bad(cmd, "`fps` must be a number above 0 and at most \(Int(maxFPS)), got \(v.serialized())")
        }
        return Float(f)
    }

    static func create(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let duration = try durationParam("timeline.create", p) ?? 30
        let fps = try fpsParam("timeline.create", p) ?? 30
        return try withTimeline(s) { $0 = Timeline(duration: duration, fps: fps) }
    }

    static func setFrame(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let f = p["frame"]?.uint64Value else { throw EngineError.bad("timeline.setFrame", "need `frame`") }
        return try withTimeline(s) { $0?.current = Int(clamping: f) }
    }

    static func step(_ s: Session, _ delta: Int64) throws -> JSONValue {
        try withTimeline(s) { $0?.step(delta) }
    }

    static func setProps(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let fps = try fpsParam("timeline.setProps", p)
        let duration = try durationParam("timeline.setProps", p)
        return try withTimeline(s) { t in
            guard var tl = t else { return }
            if let fps { tl.fps = fps }
            if let duration { tl.duration = duration }
            if let ws = p["workStart"]?.uint64Value { tl.workStart = Int(clamping: ws) }
            if let we = p["workEnd"]?.uint64Value { tl.workEnd = Int(clamping: we) }
            t = tl
        }
    }

    static func info(_ s: Session) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        guard let t = st.doc.timeline else { return ["timeline": .null] }
        return ["timeline": [
            "fps": .float(t.fps), "duration": .int(t.duration), "current": .int(t.current),
            "workStart": .int(t.workStart), "workEnd": .int(t.workEnd), "time": .float(t.time),
        ]]
    }

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("timeline.create", "Create Video Timeline", params: #"{duration?:30, fps?:30} → {timeline}"#, module: m, journal: false,
                        enabled: hasDoc, run: create),
            CommandSpec("timeline.delete", "Delete Timeline", params: "{} → {timeline:null}", module: m, journal: false, enabled: hasTimeline) { s, _ in
                try withTimeline(s) { $0 = nil }
            },
            CommandSpec("timeline.setFrame", "Go to Frame", params: #"{frame} → {timeline}"#, module: m, journal: false, enabled: hasTimeline, run: setFrame),
            CommandSpec("timeline.nextFrame", "Next Frame", params: "{} → {timeline}", module: m, journal: false, enabled: hasTimeline) { s, _ in try step(s, 1) },
            CommandSpec("timeline.previousFrame", "Previous Frame", params: "{} → {timeline}", module: m, journal: false, enabled: hasTimeline) { s, _ in
                try step(s, -1)
            },
            CommandSpec("timeline.setProps", "Timeline Settings", params: #"{fps?, duration?, workStart?, workEnd?} → {timeline}"#, module: m, journal: false,
                        enabled: hasTimeline, run: setProps),
            CommandSpec("timeline.info", "Timeline Info", params: "{} → {timeline}", module: m, journal: false, enabled: hasDoc) { s, _ in try info(s) },
        ])
    }
}
