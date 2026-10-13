// Port of photocraft-engine (crates/engine/src/timeline_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCEngine
import Testing

@Suite struct TimelineTests {
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8])
        return s
    }

    @Test func createNavigateDelete() throws {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16])
        #expect(try s.execute("timeline.info")["timeline"] == .null)
        let r = try s.execute("timeline.create", ["duration": 24, "fps": 24.0])
        #expect(r["timeline"]?["duration"] == 24)
        #expect(r["timeline"]?["current"] == 0)
        // Navigate.
        try s.execute("timeline.setFrame", ["frame": 10])
        try s.execute("timeline.nextFrame")
        #expect(try s.execute("timeline.info")["timeline"]?["current"] == 11)
        try s.execute("timeline.previousFrame")
        #expect(try s.execute("timeline.info")["timeline"]?["current"] == 10)
        // Clamp beyond the end.
        #expect(try s.execute("timeline.setFrame", ["frame": 999])["timeline"]?["current"] == 23)
        // Props.
        try s.execute("timeline.setProps", ["fps": 30.0])
        #expect(try s.execute("timeline.info")["timeline"]?["fps"] == 30.0)
        // Delete.
        try s.execute("timeline.delete")
        #expect(try s.execute("timeline.info")["timeline"] == .null)
        #expect(s.active?.history.canUndo == false, "navigation and settings add no history step")
    }

    /// The document's timeline, revision and history depth, to show a rejected command changed nothing.
    func snapshot(_ s: Session) -> (Timeline?, UInt64, Int) {
        (s.active?.doc.timeline, s.active?.revision ?? 0, s.active?.history.pastCount ?? 0)
    }

    func current(_ s: Session) throws -> JSONValue? { try s.execute("timeline.info")["timeline"]?["current"] }

    /// #1009: bad `duration` / `fps` values are rejected before anything changes.
    @Test func createRejectsOutOfRangeParams() throws {
        let s = try session()
        try s.execute("timeline.create", ["duration": 24, "fps": 24.0])
        try s.execute("timeline.setFrame", ["frame": 5])
        let before = snapshot(s)
        let bad: [JSONValue] = [
            ["duration": 0], ["duration": .number(1.8446744073709552e19)], ["duration": .number(9.223372036854775808e18)],
            ["duration": 1_000_001], ["duration": -1], ["duration": 2.5], ["duration": "24"],
            ["fps": 0.0], ["fps": -24.0], ["fps": 1001.0], ["fps": 1e300], ["fps": "fast"],
        ]
        for p in bad {
            do {
                try s.execute("timeline.create", p)
                Issue.record("\(p) must be rejected")
            } catch let e as EngineError {
                guard case .badParams = e else { Issue.record("\(p): \(e)"); continue }
            }
            let after = snapshot(s)
            #expect(after.0 == before.0 && after.1 == before.1 && after.2 == before.2, "\(p): nothing changes")
        }
        // The issue's repro: stepping still works on the surviving timeline.
        try s.execute("timeline.nextFrame")
        #expect(try current(s) == 6)
        try s.execute("timeline.previousFrame")
        #expect(try current(s) == 5)
        // Control: the largest accepted values still create a timeline that steps at both ends.
        let r = try s.execute("timeline.create", ["duration": 1_000_000, "fps": 1000.0])
        #expect(r["timeline"]?["duration"] == 1_000_000)
        try s.execute("timeline.previousFrame")
        #expect(try current(s) == 0)
        try s.execute("timeline.setFrame", ["frame": 1_000_000])
        try s.execute("timeline.nextFrame")
        #expect(try current(s) == 999_999)
        // Control: `null` means "use the default", as before.
        let d = try s.execute("timeline.create", ["duration": .null, "fps": .null])
        #expect(d["timeline"]?["duration"] == 30 && d["timeline"]?["fps"] == 30.0)
    }

    /// #1009: `timeline.setProps` could store the same out-of-range `duration` and `fps`.
    @Test func setPropsRejectsOutOfRangeParams() throws {
        let s = try session()
        try s.execute("timeline.create", ["duration": 24, "fps": 24.0])
        let before = snapshot(s)
        let bad: [JSONValue] = [["duration": 0], ["duration": .number(1.8446744073709552e19)], ["fps": 0.0], ["fps": -1.0], ["fps": 30.0, "duration": 0]]
        for p in bad {
            #expect(throws: EngineError.self, "\(p)") { try s.execute("timeline.setProps", p) }
            let after = snapshot(s)
            #expect(after.0 == before.0 && after.1 == before.1 && after.2 == before.2, "\(p): nothing changes")
        }
        try s.execute("timeline.nextFrame")
        #expect(try current(s) == 1)
    }

    /// #1009: a timeline stored with `duration` 0 or `Int.max` (an old or hand-edited file) steps
    /// without trapping and lands on a valid frame.
    @Test func stepIsSafeOnAnyStoredTimeline() throws {
        for duration in [0, 1, Int.max] {
            for current in [0, Int.max] {
                for (cmd, delta) in [("timeline.nextFrame", 1), ("timeline.previousFrame", -1)] {
                    let s = try session()
                    try s.updateActive { st in
                        st.doc.timeline = Timeline(fps: .nan, duration: duration, current: current, workStart: .max, workEnd: 0)
                    }
                    try s.execute(cmd)
                    // Read the model: JSON doubles can't tell Int.max - 1 from Int.max.
                    let t = try #require(s.active?.doc.timeline)
                    #expect(t.duration >= 1 && t.current >= 0 && t.current < t.duration, "\(cmd) d=\(duration) c=\(current): \(t)")
                    #expect(t.fps == 30 && t.workStart < t.workEnd && t.workEnd <= t.duration)
                    if duration == .max && current == 0 { #expect(t.current == (delta > 0 ? 1 : 0)) }
                }
            }
        }
    }

    @Test func navigationWithoutTimelineErrors() throws {
        let s = try session()
        #expect(throws: (any Error).self) { try s.execute("timeline.setFrame", ["frame": 1]) }
        #expect(s.disabledReason("timeline.nextFrame") == "no timeline (create one first)")
    }
}
