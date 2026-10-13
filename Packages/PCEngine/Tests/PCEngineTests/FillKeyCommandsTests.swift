// Port of photocraft-engine (crates/engine/src/fill_key_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: `fill_keys_24mp` (an ignored benchmark).

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct FillKeyCommandsTests {
    func session(_ depth: Int = 8) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 6, "background": "transparent", "depth": .int(depth)])
        try s.execute("tools.setColors", ["foreground": "#ff0000", "background": "#0000ff"])
        return s
    }

    func px(_ s: Session, _ x: Int32, _ y: Int32) -> SIMD4<Float> {
        guard let surf = s.active?.doc.layers.last?.surface else { return SIMD4(-1, -1, -1, -1) }
        return PixelCodec.toRGBA(surf.format, surf.readRegion(PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1)))
    }

    @Test func foregroundFillsTheLayerWithoutASelection() throws {
        let s = try session()
        try s.execute("edit.fillForeground")
        #expect(px(s, 0, 0) == SIMD4(1, 0, 0, 1))
        #expect(px(s, 7, 5) == SIMD4(1, 0, 0, 1))
        // One undoable "Fill" step.
        try s.execute("edit.undo")
        #expect(px(s, 0, 0).w == 0)
    }

    @Test func fillsAtEveryBitDepth() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            try s.execute("select.rect", ["x": 0, "y": 0, "width": 4, "height": 6])
            try s.execute("edit.fillForeground")
            try s.execute("select.deselect")
            try s.execute("edit.fillBackgroundPreserve")
            let p = px(s, 1, 1)
            #expect(abs(p.x) < 1e-3 && abs(p.y) < 1e-3 && abs(p.z - 1) < 1e-3 && abs(p.w - 1) < 1e-3, "\(depth)-bit: \(p)")
            #expect(px(s, 6, 1).w == 0, "\(depth)-bit")
        }
    }

    @Test func fillFromHistoryRestoresTheHistoryBrushSourceInTheSelection() throws {
        let s = try session()
        #expect(s.registry.spec("edit.fillHistory")?.shortcut == "Cmd+Alt+Backspace")
        try s.execute("edit.fillForeground")
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 4, "height": 6])
        try s.execute("edit.fillHistory")
        // The oldest state (the new, transparent layer) comes back inside the selection only.
        #expect(px(s, 1, 1).w == 0)
        #expect(px(s, 6, 1) == SIMD4(1, 0, 0, 1))
        // A named state, and refused ones change nothing.
        try s.execute("select.deselect")
        let steps = s.active?.history.pastCount
        for bad: JSONValue in [["state": 99], ["state": "x"], 7] {
            #expect(throws: (any Error).self, "\(bad.serialized())") { try s.execute("edit.fillHistory", bad) }
        }
        #expect(s.active?.history.pastCount == steps)
        try s.execute("edit.fillHistory", ["state": 1])
        #expect(px(s, 1, 1) == SIMD4(1, 0, 0, 1), "state 1 is after the foreground fill")
    }

    @Test func backgroundFillsOnlyTheSelection() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 2, "y": 1, "width": 3, "height": 2])
        try s.execute("edit.fillBackground")
        #expect(px(s, 3, 2) == SIMD4(0, 0, 1, 1))
        #expect(px(s, 0, 0).w == 0)
        #expect(px(s, 5, 1).w == 0)
    }

    @Test func preserveTransparencyRecoloursOnlyExistingPixels() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 2, "height": 2])
        try s.execute("edit.fillBackground")
        try s.execute("select.deselect")
        try s.execute("edit.fillForegroundPreserve")
        #expect(px(s, 1, 1) == SIMD4(1, 0, 0, 1))
        #expect(px(s, 4, 4).w == 0, "transparent pixels stay transparent")
        try s.execute("edit.fillBackgroundPreserve")
        #expect(px(s, 0, 0) == SIMD4(0, 0, 1, 1))
        #expect(px(s, 4, 4).w == 0)
        // Without ⇧ the whole layer fills.
        try s.execute("edit.fillForeground")
        #expect(px(s, 4, 4) == SIMD4(1, 0, 0, 1))
    }

    @Test func paramsCannotChangeTheColourAndBadParamsFailGracefully() throws {
        let s = try session()
        try s.execute("edit.fillForeground", ["color": "#00ff00", "opacity": 10])
        #expect(px(s, 0, 0) == SIMD4(1, 0, 0, 1))
        for id in FillKeyCommands.ids {
            #expect(throws: (any Error).self) { try s.execute(id, [1, 2]) }
            #expect(throws: (any Error).self) { try s.execute(id, "x") }
            #expect(throws: (any Error).self) { try s.execute(id, ["layer": 99_999]) }
            #expect(throws: (any Error).self) { try s.execute(id, ["target": ["channel": 42]]) }
        }
    }

    @Test func lockedLayerAndNoDocumentAreErrors() throws {
        let s0 = Session()
        for id in FillKeyCommands.ids {
            #expect(throws: (any Error).self, "\(id) without a document") { try s0.execute(id) }
        }
        let s = try session()
        try s.execute("layer.lockLayers", ["pixels": true])
        for id in FillKeyCommands.ids {
            do {
                try s.execute(id)
                Issue.record("\(id): expected an error")
            } catch {
                #expect("\(error)".contains("locked"), "\(id): \(error)")
            }
        }
        #expect(px(s, 0, 0).w == 0)
    }

    @Test func registeredWithPhotoshopDefaultShortcuts() {
        let r = CommandRegistry.standard()
        #expect(r.spec("edit.fillForeground")?.shortcut == "Alt+Backspace")
        #expect(r.spec("edit.fillBackground")?.shortcut == "Cmd+Backspace")
        #expect(r.spec("edit.fillForegroundPreserve")?.shortcut == "Alt+Shift+Backspace")
        #expect(r.spec("edit.fillBackgroundPreserve")?.shortcut == "Cmd+Shift+Backspace")
    }
}
