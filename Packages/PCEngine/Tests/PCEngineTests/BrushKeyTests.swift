// Port of photocraft-engine (crates/engine/src/brush_key_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
@testable import PCEngine
import Testing

@Suite struct BrushKeyTests {
    @Test func stepsLikePhotoshop() {
        typealias B = BrushKeyCommands
        #expect(B.sizeStep(1, false) == 1, "never below 1 px")
        #expect(B.sizeStep(1, true) == 2, "small brushes still grow")
        #expect(B.sizeStep(2, false) == 1, "small brushes still shrink (#3229)")
        #expect(B.sizeStep(3, false) == 2)
        #expect(B.sizeStep(4, false) == 3)
        for size: Float in [2, 3, 5, 8, 13, 100] {
            #expect(B.sizeStep(size, false) < size, "`[` always shrinks \(size)")
            #expect(B.sizeStep(size, true) > size, "`]` always grows \(size)")
        }
        #expect(B.sizeStep(100, true) == 125)
        #expect(B.sizeStep(125, false) == 100)
        #expect(B.sizeStep(B.maxSize, true) == B.maxSize, "never past the largest brush")
        #expect(B.hardnessStep(0.5, true) == 0.75)
        #expect(B.hardnessStep(0.6, false) == 0.25, "snaps to the quarter below the nearest")
        #expect(B.hardnessStep(1, true) == 1)
        #expect(B.hardnessStep(0, false) == 0)
    }

    @Test func rotateBrushTurnsTheTipAndWrapsAt180() throws {
        typealias B = BrushKeyCommands
        #expect(B.turned(0, 1) == 1)
        #expect(B.turned(179, 15) == -166)
        #expect(B.turned(-175, -15) == 170)
        #expect(B.turned(180, 0) == 180)
        let s = Session()
        try s.execute("tools.rotateBrush", ["degrees": -15])
        #expect(s.tools.brush.angle == -15)
        for bad: JSONValue in [[:], ["degrees": "x"], ["degrees": 1e9], .null] {
            #expect(throws: EngineError.self, "\(bad)") { try s.execute("tools.rotateBrush", bad) }
        }
        #expect(s.tools.brush.angle == -15)
    }

    @Test func commandsStepTheSessionBrushAndJournal() throws {
        let s = Session()
        try s.execute("tools.setBrush", ["brush": ["size": 40, "hardness": 0.5]])
        try s.execute("tools.increaseBrushSize")
        #expect(s.tools.brush.size == 50)
        try s.execute("tools.decreaseBrushSize", .null)
        #expect(s.tools.brush.size == 40)
        // Pixel artists: `[` held down reaches 1 px (#3229).
        try s.execute("tools.setBrush", ["brush": ["size": 3]])
        for expected: Float in [2, 1, 1] {
            try s.execute("tools.decreaseBrushSize", .null)
            #expect(s.tools.brush.size == expected)
        }
        try s.execute("tools.increaseBrushHardness")
        #expect(s.tools.brush.hardness == 0.75)
        try s.execute("tools.decreaseBrushHardness", ["junk": [1, 2]])
        #expect(s.tools.brush.hardness == 0.5)
        #expect(s.journal.last?.id == "tools.decreaseBrushHardness")
        // They need no document and are bindable under Tools.
        #expect(s.registry.spec("tools.decreaseBrushSize")?.shortcut == "[")
        #expect(s.registry.spec("tools.increaseBrushHardness")?.shortcut == "Shift+]")
    }
}
