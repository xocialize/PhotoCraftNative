// Port of photocraft-engine (crates/engine/src/brush_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPaint
import Testing

/// Shared helpers for the painting suites.
enum PaintTestKit {
    static func session(_ w: Int, _ h: Int, background: String = "transparent", depth: Int = 8, mode: String = "rgb") throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h), "background": .string(background), "depth": .int(depth), "mode": .string(mode)])
        return s
    }

    static func surface(_ s: Session) -> Surface {
        guard let d = s.active, let id = d.activeLayer, let surf = d.doc.layer(id)?.surface else { return Surface(format: .rgba8) }
        return surf
    }

    static func rgba(_ s: Session, _ x: Int32, _ y: Int32) -> SIMD4<Float> { surface(s).rgba(x: x, y: y) }

    static func samePixels(_ a: Surface, _ b: Surface, _ r: PixelRect) -> Bool {
        a.readRegion(r) == b.readRegion(r)
    }

    /// What `edit.fill` does for the tests (that command belongs to another module): `color`
    /// composited over `rect` (default the canvas) of the active layer, through the selection.
    static func fill(_ s: Session, _ color: SIMD4<Float>, _ rect: PixelRect? = nil) throws {
        try s.edit("Fill") { doc, active in
            guard let id = active else { throw EngineError.other("no active layer") }
            let r = rect ?? doc.bounds
            let sel = doc.selection
            _ = doc.withRaster(of: id) { Pixels.fillSurface(&$0, r, color: color, selection: sel, lockTransparency: false) }
        }
    }

    static func points(_ pts: [[Double]]) -> JSONValue { .array(pts.map { .array($0.map { .number($0) }) }) }

    static func sp(_ q: [Double]) -> StrokePoint { StrokePoint(q[0], q[1], Float(q.count > 2 ? q[2] : 1)) }
}

@Suite struct BrushTests {
    typealias K = PaintTestKit

    @Test func strokeBackwardsCompatible() throws {
        let s = try K.session(80, 40)
        let r = try s.execute("paint.stroke", ["points": [[4, 20], [60, 20]], "size": 6, "color": "#0000ff"])
        #expect(r["damage"]?.arrayValue?.count == 4)
        #expect(K.rgba(s, 30, 20) == SIMD4(0, 0, 1, 1))
        #expect(K.rgba(s, 30, 30).w == 0)
        // [x, y, pressure] with the default pressure-size brush: light pressure → thinner line.
        try s.execute("paint.stroke", ["points": [[4, 5, 0.2], [60, 5, 0.2]], "size": 10])
        #expect(K.rgba(s, 30, 5).w > 0.9 && K.rgba(s, 30, 8).w < 0.01)
    }

    @Test func strokeAcceptsFullPointsBrushAndPreset() throws {
        let s = try K.session(200, 100)
        // 7-tuples plus a brush object with tilt-driven angle on a flat tip.
        let brush: JSONValue = ["size": 30, "roundness": 0.2, "pressureSize": false, "spacing": 0.1,
                                "shapeDynamics": ["enabled": true, "angle": ["control": "penTilt"]]]
        try s.execute("paint.stroke", ["points": [[50, 50, 1, 0, -45, 0, 0], [52, 50, 1, 0, -45, 0, 16]], "brush": brush])
        // Tilt up = 90°: the flat tip stands vertically.
        #expect(K.rgba(s, 50, 40).w > 0.9 && K.rgba(s, 50, 60).w > 0.9 && K.rgba(s, 60, 50).w < 0.01)
        // Object points.
        try s.execute("paint.stroke", ["points": [["x": 150, "y": 20], ["x": 180, "y": 20, "pressure": 1.0]], "size": 4, "brush": ["pressureSize": false]])
        #expect(K.rgba(s, 165, 20).w > 0.9)
        // Presets by name.
        try s.execute("paint.stroke", ["points": [[20, 80], [120, 80]], "preset": "Hard Round"])
        #expect(K.rgba(s, 70, 80).w > 0.99)
        #expect(throws: EngineError.self) { try s.execute("paint.stroke", ["points": [[1, 1]], "preset": "Nope"]) }
        #expect(throws: EngineError.self) { try s.execute("paint.stroke", ["points": [[1, 1]], "brush": ["size": "big"]]) }
    }

    @Test func paintCommandsBoundHostileTimeAndRejectOversizedBrushes() throws {
        let s = try K.session(32, 32)
        try s.execute("paint.stroke", ["points": [[16, 16, 1, 0, 0, 0, 0], [16, 16, 1, 0, 0, 0, .number(1.7976931348623157e308)]],
                                       "brush": ["buildUp": true, "buildUpRate": 1000, "size": 4, "pressureSize": false]])
        for command in ["paint.stroke", "paint.pencil"] {
            #expect(throws: EngineError.self, "\(command) must reject an oversized brush") { try s.execute(command, ["points": [[8, 8]], "size": 1e30]) }
        }
        #expect(throws: EngineError.self) { try s.execute("paint.stroke", ["points": [[8, 8]], "brush": ["dualBrush": ["enabled": true, "size": 1e30]]]) }
        try s.execute("tools.setBrush", ["size": 5000])
        #expect(throws: EngineError.self) { try s.execute("tools.setBrush", ["size": 5001]) }
        #expect(s.tools.brush.size == 5000, "a rejected brush update must not change the session brush")
    }

    @Test func replayIsDeterministic() throws {
        let params: JSONValue = ["points": [[10, 50], [60, 30, 0.7], [120, 60, 0.9], [180, 40]], "preset": "Spatter", "color": "#ff8800"]
        func run() throws -> Session {
            let s = try K.session(200, 100)
            try s.execute("paint.stroke", params)
            try s.execute("tools.setBrush", ["preset": "Confetti"])
            try s.execute("paint.stroke", ["points": [[10, 80], [190, 80]]])
            return s
        }
        let (a, b) = (try run(), try run())
        let r = PixelRect(x: 0, y: 0, width: 200, height: 100)
        #expect(K.samePixels(K.surface(a), K.surface(b), r))
        // Replaying the journal into a fresh session reproduces the pixels.
        let c = try K.session(200, 100)
        for inv in a.journal.dropFirst() { try c.execute(inv) }
        #expect(K.samePixels(K.surface(a), K.surface(c), r))
        // A different explicit seed changes the scatter.
        let d = try K.session(200, 100)
        try d.execute("paint.stroke", params.setting("seed", 12345))
        let e = try K.session(200, 100)
        try e.execute("paint.stroke", params)
        #expect(!K.samePixels(K.surface(d), K.surface(e), r))
    }

    @Test func pencilIsAliasedAndAutoErases() throws {
        let s = try K.session(60, 30)
        try s.execute("paint.pencil", ["points": [[5, 10.3], [50, 10.3]], "size": 5, "color": "#000000"])
        let surf = K.surface(s)
        for y in Int32(0)..<30 {
            for x in Int32(0)..<60 {
                let a = surf.rgba(x: x, y: y).w
                #expect(a == 0 || a == 1)
            }
        }
        try s.execute("tools.setColors", ["foreground": "#000000", "background": "#ffffff"])
        // Starting on a foreground pixel: paints background.
        try s.execute("paint.pencil", ["points": [[20, 10], [20, 25]], "size": 3, "autoErase": true])
        #expect(K.rgba(s, 20, 22) == SIMD4(1, 1, 1, 1))
        // Starting elsewhere: paints foreground.
        try s.execute("paint.pencil", ["points": [[40, 25], [40, 28]], "size": 3, "autoErase": true])
        #expect(K.rgba(s, 40, 26) == SIMD4(0, 0, 0, 1))
    }

    @Test func mixerBrushReservoirAndCleaning() throws {
        let s = try K.session(200, 30)
        try s.execute("tools.setColors", ["foreground": "#ff0000"])
        try s.execute("paint.mixerBrush", ["points": [[5, 15], [195, 15]], "size": 8, "wet": 0, "load": 0, "mix": 0,
                                           "brush": ["pressureSize": false, "spacing": 0.25]])
        #expect(K.rgba(s, 10, 15).w > 0.95 && K.rgba(s, 190, 15).w < 0.5, "low load dries out")
        #expect(s.state[BrushCommands.MixerKey.self].pickup == nil, "cleaned after stroke")
        // Wet, not cleaned: the pickup persists into the session.
        try s.execute("paint.mixerBrush", ["points": [[5, 5], [100, 5]], "size": 8, "wet": 100, "mix": 80, "cleanAfterStroke": false])
        #expect(s.state[BrushCommands.MixerKey.self].pickup != nil)
        // Sample All Layers path runs.
        try s.execute("paint.mixerBrush", ["points": [[5, 25], [50, 25]], "size": 6, "sampleAllLayers": true])
    }

    @Test func colorReplacementModes() throws {
        let s = try K.session(60, 40, background: "#33993f")
        try s.execute("tools.setColors", ["foreground": "#ff0000"])
        let before = K.rgba(s, 30, 20)
        try s.execute("paint.colorReplacement", ["points": [[10, 20], [50, 20]], "size": 20, "mode": "color", "tolerance": 20])
        let c = K.rgba(s, 30, 20)
        func lum(_ c: SIMD4<Float>) -> Float { Blend.lum(SIMD3(c.x, c.y, c.z)) }
        #expect(c.x > c.y, "\(c)")
        #expect(abs(lum(c) - lum(before)) < 0.02)
        try s.execute("paint.colorReplacement", ["points": [[10, 5], [50, 5]], "size": 6, "mode": "luminosity", "sampling": "once", "limits": "discontiguous"])
        #expect(abs(lum(K.rgba(s, 30, 5)) - 0.3) < 0.02)
        #expect(throws: EngineError.self) { try s.execute("paint.colorReplacement", ["points": [[1, 1]], "mode": "bogus"]) }
    }

    /// Color Replacement recolours layer pixels only: a mask, channel or Quick Mask target is
    /// refused. (photocraft's live half of this test needs the retouch module's `LiveDab`.)
    @Test func colorReplacementRefusesNonPixelTargets() throws {
        let s = try K.session(20, 20, background: "#ff0000")
        let steps = s.active?.history.entries.count ?? 0
        for t: JSONValue in ["mask", "quickMask", ["channel": 0], 3] {
            #expect(throws: EngineError.self, "\(t)") { try s.execute("paint.colorReplacement", ["points": [[10, 10]], "size": 6, "target": t]) }
        }
        #expect(s.active?.history.entries.count == steps)
        try s.execute("paint.colorReplacement", ["points": [[10, 10]], "size": 6, "target": "pixels"])
        #expect(s.active?.history.entries.count == steps + 1)
    }

    @Test func presetsSaveLoadDeleteRoundTrip() throws {
        let s = try K.session(10, 10)
        let n0 = try s.execute("brush.presets.list")["presets"]?.arrayValue?.count ?? 0
        #expect(n0 >= 12)
        try s.execute("brush.presets.save", ["name": "Mine", "brush": ["size": 77, "scattering": ["enabled": true, "count": 3]]])
        let list = try s.execute("brush.presets.list", ["full": true])
        let mine = try #require(list["presets"]?.arrayValue?.first { $0["name"] == "Mine" })
        #expect(mine["brush"]?["size"] == 77.0)
        #expect(mine["brush"]?["scattering"]?["count"] == 3)
        // Round trip: select it, read it back.
        let b = try s.execute("tools.setBrush", ["preset": "mine"])
        #expect(b["size"] == 77.0)
        let back = try s.execute("brush.get").decode(as: BrushSettings.self)
        #expect(back == s.tools.brush)
        // Overwrite, then delete.
        try s.execute("brush.presets.save", ["name": "Mine"])
        #expect(s.tools.presets.count == n0 + 1)
        try s.execute("brush.presets.delete", ["name": "Mine"])
        #expect(s.tools.presets.count == n0)
        #expect(throws: EngineError.self) { try s.execute("brush.presets.delete", ["name": "Mine"]) }
        #expect(throws: EngineError.self) { try s.execute("brush.presets.save", [:]) }
    }

    @Test func presetsSaveAppendsAtTheEndAndUpdateOverwritesInPlace() throws {
        let s = try K.session(10, 10)
        try s.execute("tools.setBrush", ["preset": "Chalk"])
        #expect(s.tools.currentPreset == "Chalk")
        let n = s.tools.presets.count
        let chalkAt = s.tools.presets.firstIndex { $0.name == "Chalk" }
        // A new preset appends at the end, picked preset or not.
        try s.execute("brush.presets.save", ["name": "Mine"])
        #expect(s.tools.presets.last?.name == "Mine")
        try s.execute("brush.presets.save", ["name": "Tail"])
        #expect(s.tools.presets.last?.name == "Tail")
        // A reset clears the picked preset.
        try s.execute("tools.setBrush", ["reset": true])
        #expect(s.tools.currentPreset == nil)
        // Editing the brush keeps the picked preset current; update overwrites it in place.
        try s.execute("tools.setBrush", ["preset": "Chalk"])
        try s.execute("tools.setBrush", ["size": 55])
        #expect(s.tools.currentPreset == "Chalk")
        let r = try s.execute("brush.presets.update", [:])
        #expect(r["name"] == "Chalk")
        #expect(s.tools.presets.count == n + 2, "no new preset (the two saves added two)")
        #expect(s.tools.presets.firstIndex { $0.name == "Chalk" } == chalkAt)
        let chalk = try #require(s.tools.presets.first { $0.name == "Chalk" })
        #expect(chalk.brush.size == 55)
        #expect(!chalk.builtin, "an updated built-in becomes the user's preset")
        // A named update of another preset.
        try s.execute("brush.presets.update", ["name": "Mine", "brush": ["size": 9]])
        #expect(s.tools.presets.first { $0.name == "Mine" }?.brush.size == 9)
        // Errors: no such preset, and no preset to update after a reset.
        #expect(throws: EngineError.self) { try s.execute("brush.presets.update", ["name": "Nope"]) }
        try s.execute("tools.setBrush", ["reset": true])
        #expect(throws: EngineError.self) { try s.execute("brush.presets.update", [:]) }
        // Deleting the current preset clears it, so a later update fails rather than guessing.
        try s.execute("tools.setBrush", ["preset": "Chalk"])
        try s.execute("brush.presets.delete", ["name": "Chalk"])
        #expect(s.tools.currentPreset == nil)
        #expect(throws: EngineError.self) { try s.execute("brush.presets.update", [:]) }
    }

    @Test func aFailedSetBrushLeavesNoCurrentPresetBehind() throws {
        let s = try K.session(10, 10)
        let before = s.tools.brush
        #expect(throws: EngineError.self) { try s.execute("tools.setBrush", ["preset": "Chalk", "brush": ["size": "big"]]) }
        #expect(s.tools.currentPreset == nil)
        #expect(s.tools.brush == before)
        try s.execute("tools.setBrush", ["preset": "Chalk"])
        #expect(s.tools.currentPreset == "Chalk")
        // A `reset` wins over a `preset` in the same call.
        try s.execute("tools.setBrush", ["preset": "Chalk", "reset": true])
        #expect(s.tools.currentPreset == nil)
    }

    @Test func setBrushMergesFields() throws {
        let s = try K.session(10, 10)
        try s.execute("tools.setBrush", ["size": 55, "shapeDynamics": ["enabled": true, "size": ["jitter": 0.5]]])
        try s.execute("tools.setBrush", ["shapeDynamics": ["angle": ["jitter": 0.25]]])
        let b = s.tools.brush
        #expect(b.size == 55)
        #expect(b.shapeDynamics.enabled && b.shapeDynamics.size.jitter == 0.5 && b.shapeDynamics.angle.jitter == 0.25)
        try s.execute("tools.setBrush", ["reset": true])
        #expect(s.tools.brush == BrushSettings())
        // Protect texture carries the pattern across textured presets.
        try s.execute("tools.setBrush", ["preset": "Chalk", "protectTexture": true])
        let chalkPattern = s.tools.brush.texture.pattern
        try s.execute("tools.setBrush", ["preset": "Canvas Texture"])
        #expect(s.tools.brush.texture.pattern == chalkPattern)
    }

    @Test func setBrushKeepsUntouchedBitmapsAndReplacesTouchedOnes() throws {
        func tile(_ w: UInt32, _ h: UInt32, _ k: UInt32) -> GrayTile { GrayTile(width: w, height: h) { x, y in Float((x * k + y) % 5) / 4 } }
        var base = BrushSettings()
        base.tip = .sampled(tile(900, 700, 3))
        base.dualBrush.tip = .sampled(tile(30, 20, 2))
        base.texture.pattern = .tile(tile(64, 64, 1))
        let cmd = "tools.setBrush"
        // Untouched bitmaps survive any patch that doesn't name them.
        for patch: JSONValue in [["size": 12], ["dualBrush": ["size": 9]], ["texture": ["depth": 0.5]], [:]] {
            let b = try BrushCommands.mergeBrush(base, patch, cmd)
            #expect(b.tip == base.tip && b.dualBrush.tip == base.dualBrush.tip && b.texture.pattern == base.texture.pattern, "\(patch)")
        }
        let b = try BrushCommands.mergeBrush(base, ["size": 12, "dualBrush": ["size": 9]], cmd)
        #expect(b.size == 12 && b.dualBrush.size == 9)
        // Named ones are replaced.
        let r = try BrushCommands.mergeBrush(base, ["tip": "round", "dualBrush": ["tip": "round"],
                                                    "texture": ["pattern": ["procedural": ["style": "dots", "size": 32, "seed": 2]]]], cmd)
        #expect(r.tip == .round && r.dualBrush.tip == .round)
        if case .procedural(_, let size, _) = r.texture.pattern { #expect(size == 32) } else { Issue.record("expected a procedural pattern") }
        // A section replaced by a non-object is an error, not a silently kept bitmap.
        #expect(throws: EngineError.self) { try BrushCommands.mergeBrush(base, ["dualBrush": 3], cmd) }
        #expect(throws: EngineError.self) { try BrushCommands.mergeBrush(base, .null, cmd) }
    }

    @Test func defineBrushFromSelection() throws {
        let s = try K.session(40, 40)
        #expect(throws: EngineError.self, "needs a selection") { try s.execute("brush.defineFromSelection", ["name": "Blob"]) }
        // A black 6×4 block inside a larger selection.
        try K.fill(s, SIMD4(0, 0, 0, 1), PixelRect(x0: 10, y0: 12, x1: 16, y1: 16))
        try s.execute("select.rect", ["x": 5, "y": 5, "width": 20, "height": 20])
        let r = try s.execute("brush.defineFromSelection", ["name": "Blob"])
        #expect(r["width"]?.intValue == 6 && r["height"]?.intValue == 4)
        #expect(s.tools.brush.size == 6)
        if case .sampled(let t) = s.tools.brush.tip {
            #expect(t.width == 6 && t.height == 4 && t.get(0, 0) == 1)
        } else {
            Issue.record("expected a sampled tip")
        }
        #expect(s.tools.presets.contains { $0.name == "Blob" })
        // Paint with it.
        try s.execute("select.deselect")
        try s.execute("paint.stroke", ["points": [[30, 32]], "color": "#ff0000"])
        #expect(K.rgba(s, 30, 32).w > 0.9)
    }

    @Test func worksOnCMYKAnd16Bit() throws {
        for (mode, depth) in [("cmyk", 8), ("rgb", 16), ("grayscale", 32)] {
            let s = Session()
            try s.execute("file.new", ["width": 60, "height": 30, "mode": .string(mode), "depth": .int(depth)])
            try s.execute("paint.stroke", ["points": [[5, 15], [55, 15]], "preset": "Chalk", "color": "#000000"])
            try s.execute("paint.pencil", ["points": [[5, 5], [55, 5]], "size": 2, "color": "#000000"])
            #expect(K.rgba(s, 30, 5).x < 0.2, "\(mode)/\(depth): \(K.rgba(s, 30, 5))")
        }
    }

    @Test func brushBlendModeMultiply() throws {
        // Painting with a blend mode (options-bar "Mode"): blue × yellow = black (Multiply).
        let s = try K.session(40, 40)
        try K.fill(s, SIMD4(1, 1, 0, 1))
        try s.execute("paint.stroke", ["points": [[5, 20], [35, 20]], "size": 12, "color": "#0000ff", "mode": "multiply", "brush": ["hardness": 1.0]])
        let c = K.rgba(s, 20, 20)
        #expect(c.x < 0.1 && c.y < 0.1 && c.z < 0.1, "multiply blue×yellow ≈ black: \(c)")
        // Normal mode paints opaque blue at the same spot.
        let s2 = try K.session(40, 40)
        try K.fill(s2, SIMD4(1, 1, 0, 1))
        try s2.execute("paint.stroke", ["points": [[5, 20], [35, 20]], "size": 12, "color": "#0000ff", "brush": ["hardness": 1.0]])
        let n = K.rgba(s2, 20, 20)
        #expect(n.z > 0.9 && n.x < 0.1, "normal paints blue: \(n)")
    }

    @Test func eraserOnBackgroundLayerPaintsTheBackgroundColour() throws {
        // Issue #15: erasing the Background layer (locked transparency) paints the background colour.
        let s = try K.session(20, 20, background: "white")
        try s.execute("tools.setColors", ["background": "#ff0000"])
        try s.execute("paint.stroke", ["points": [[2, 10], [18, 10]], "size": 8, "erase": true, "brush": ["hardness": 1.0]])
        let surf = try #require(s.active?.doc.layers[0].surface)
        let c = surf.rgba(x: 10, y: 10)
        #expect(c.x > 0.9 && c.y < 0.1 && c.z < 0.1 && c.w > 0.99, "erased to opaque background red: \(c)")
        let w = surf.rgba(x: 10, y: 2)
        #expect(w.x > 0.9 && w.y > 0.9 && w.z > 0.9, "untouched stays white: \(w)")
    }

    @Test func liveStrokeMatchesTheCommittedStroke() throws {
        // The canvas previews strokes with `LiveStroke`; it must show what `paint.stroke` commits.
        let s = try K.session(200, 100)
        let pts: [[Double]] = [[10, 50, 1], [60, 30, 0.7], [120, 60, 0.9], [180, 40, 1]]
        let p: JSONValue = ["points": K.points([pts[0]]), "preset": "Spatter", "brush": ["hardness": 0.0], "smoothing": 0.0, "target": "pixels"]
        var live = try BrushCommands.LiveStroke.begin(s, p)
        for i in stride(from: 1, to: pts.count, by: 2) {
            let chunk = pts[i..<min(i + 2, pts.count)].map(K.sp)
            #expect(!(try live.push(chunk)).isEmpty)
        }
        try s.execute("paint.stroke", p.setting("points", K.points(pts)).setting("seed", .int(live.seed)))
        let id = try #require(s.active?.activeLayer)
        let shown = try #require(live.doc.layer(id)?.surface)
        #expect(K.samePixels(shown, K.surface(s), PixelRect(x: 0, y: 0, width: 200, height: 100)))
        let a = shown.readRGBA(PixelRect(x: 0, y: 0, width: 200, height: 100))
        #expect(a.contains { $0.w > 0.05 && $0.w < 0.95 }, "soft edge previewed")
        // Bad input is an error, not a crash.
        #expect(throws: EngineError.self) { try BrushCommands.LiveStroke.begin(s, ["points": []]) }
        #expect(throws: EngineError.self) { try BrushCommands.LiveStroke.begin(s, ["points": [[1, 1]], "target": ["channel": 9]]) }
        #expect(throws: EngineError.self) { try BrushCommands.LiveStroke.begin(Session(), ["points": [[1, 1]]]) }
    }

    @Test func strokeCoordinateValidationKeepsTheExistingBounds() throws {
        let mc = BrushCommands.maxCoord
        try BrushCommands.checkCoords([StrokePoint(-mc, mc, 1), StrokePoint(mc, -mc, 1)], "paint.stroke")
        try BrushCommands.checkCoords([], "paint.stroke")
        for (x, y) in [(mc + 1, 0.0), (0, -mc - 1), (Double.nan, 0), (0, Double.infinity)] {
            #expect(throws: EngineError.self) { try BrushCommands.checkCoords([StrokePoint(x, y, 1)], "paint.stroke") }
        }
        #expect(throws: EngineError.self) { try BrushCommands.parsePoints(["points": []], "paint.stroke") }
        _ = try BrushCommands.parsePoints(["points": [[.number(mc), .number(-mc)]]], "paint.stroke")
    }

    @Test func liveBrushAndPencilRejectInvalidBatchesWithoutChangingThePreview() throws {
        for depth in [8, 16, 32] {
            let s = try K.session(32, 32, depth: depth)
            let st = try #require(s.active)
            let id = try #require(st.activeLayer)
            for (cmd, erase) in [("paint.stroke", false), ("paint.stroke", true), ("paint.pencil", false)] {
                let p: JSONValue = ["points": [[8, 16]], "size": 4, "erase": .bool(erase), "seed": 7]
                var live = try BrushCommands.LiveStroke.beginWith(s, cmd, p)
                var control = try BrushCommands.LiveStroke.beginWith(s, cmd, p)
                for (x, y) in [(Double.nan, 16.0), (16, .nan), (.infinity, 16), (16, -.infinity), (1e300, 16), (16, -BrushCommands.maxCoord - 1)] {
                    let shown = live.doc
                    let bounds = live.bounds
                    do {
                        _ = try live.push([StrokePoint(12, 18, 1), StrokePoint(x, y, 1)])
                        Issue.record("expected an error")
                    } catch EngineError.badParams(let c, let msg) {
                        #expect(c == cmd && msg.contains("point coordinates must be finite"))
                    }
                    #expect(shown == live.doc, "reject the whole batch before touching the preview")
                    #expect(live.bounds == bounds)
                }
                // A rejected batch must not advance the renderer.
                let next = [StrokePoint(-4, 16, 1), StrokePoint(24, 16, 1)]
                #expect(try live.push(next) == (try control.push(next)))
                #expect(live.bounds == control.bounds)
                let got = try #require(live.doc.layer(id)?.surface), want = try #require(control.doc.layer(id)?.surface)
                #expect(K.samePixels(got, want, live.bounds))
                #expect(got.contentBounds == want.contentBounds)
            }
            let after = try #require(s.active)
            #expect(after.doc == st.doc && after.revision == st.revision && after.history.pastCount == st.history.pastCount)
        }
    }

    @Test func livePencilMatchesTheCommittedPencilAndAutoErases() throws {
        let s = try K.session(80, 40)
        try s.execute("tools.setColors", ["foreground": "#000000", "background": "#ffffff"])
        // A soft, low-flow session brush: the Pencil is still hard, aliased and full flow.
        try s.execute("tools.setBrush", ["brush": ["size": 3, "hardness": 0.0, "flow": 0.3]])
        let pts: [[Double]] = [[5, 5, 1], [30.2, 17.7, 0.6], [70, 33, 1]]
        for (auto, start) in [(false, pts[0]), (true, [30.4, 17.2, 1])] {
            let p: JSONValue = ["points": K.points([start]), "autoErase": .bool(auto), "smoothing": 0.0]
            var live = try BrushCommands.LiveStroke.beginWith(s, "paint.pencil", p)
            try live.push(pts.map(K.sp))
            try s.execute("paint.pencil", p.setting("points", K.points([start] + pts)).setting("seed", .int(live.seed)))
            let id = try #require(s.active?.activeLayer)
            let shown = try #require(live.doc.layer(id)?.surface)
            let r = PixelRect(x: 0, y: 0, width: 80, height: 40)
            #expect(K.samePixels(shown, K.surface(s), r), "auto erase \(auto)")
            #expect(shown.readRGBA(r).allSatisfy { $0.w == 0 || $0.w == 1 }, "partial alpha")
        }
        // The second stroke started on the first one's black: Auto Erase painted white.
        #expect(K.rgba(s, 70, 33) == SIMD4(1, 1, 1, 1))
        // Only the Brush and the Pencil stroke live.
        #expect(throws: EngineError.self) { try BrushCommands.LiveStroke.beginWith(s, "paint.mixerBrush", ["points": [[1, 1]]]) }
        #expect(throws: EngineError.self) { try BrushCommands.LiveStroke.beginWith(s, "paint.pencil", ["points": "none"]) }
    }

    @Test func liveStrokeEqualsTheCommitAtEveryZoomWithSmoothing() throws {
        // #189: the preview while dragging must be the committed stroke (within 1/255), with a soft
        // brush on an opaque Background with content, at any zoom, with smoothing on, pressure, 8
        // and 16 bits, and points fed one pointer move at a time.
        let pts: [[Double]] = (0..<40).map { i in
            let t = Double(i) / 39
            return [40 + 120 * t, 60 + 30 * sin(t * 7), 0.3 + 0.7 * t]
        }
        for depth in [8, 16] {
            for zoom in [0.25, 1.0, 4.0, 16.0] {
                for (amount, pulled) in [(0.1, false), (0.5, false), (0.3, true)] {
                    let s = try K.session(200, 120, background: "white", depth: depth)
                    try K.fill(s, SIMD4(Float(0x1a) / 255, Float(0x25) / 255, Float(0x50) / 255, 1))
                    try s.execute("paint.stroke", ["points": [[20, 20], [180, 100]], "size": 8, "hardness": 1.0, "color": "#ffffff"])
                    s.tools.foreground = SIMD4(0, 0, 0, 1)
                    let brush: JSONValue = ["size": 40, "hardness": 0.0, "pressureSize": true, "smoothing": ["amount": .number(amount), "pulledString": .bool(pulled)]]
                    let p: JSONValue = ["points": K.points([pts[0]]), "brush": brush, "zoom": .number(zoom), "target": "pixels"]
                    var live = try BrushCommands.LiveStroke.begin(s, p)
                    for q in pts.dropFirst() { try live.push([K.sp(q)]) }
                    try s.execute("paint.stroke", p.setting("points", K.points(pts)).setting("seed", .int(live.seed)))
                    let id = try #require(s.active?.activeLayer)
                    let r = PixelRect(x: 0, y: 0, width: 200, height: 120)
                    let shown = try #require(live.doc.layer(id)?.surface).readRGBA(r)
                    let doneSurf = K.surface(s)
                    let done = doneSurf.readRGBA(r)
                    var worst: Float = 0
                    for i in shown.indices {
                        let d = shown[i] - done[i]
                        worst = max(worst, abs(d.x), abs(d.y), abs(d.z), abs(d.w))
                    }
                    let label = "depth \(depth), zoom \(zoom), smoothing \(amount) (pulled string \(pulled))"
                    #expect(worst <= 1 / 255, "\(label): preview differs from the commit by \(worst)")
                    let edge = doneSurf.rgba(x: 40, y: 60 - 14).z
                    #expect(doneSurf.rgba(x: 40, y: 60).x < 0.1 && edge >= 0.05 && edge < 0.9, "\(label): soft stroke")
                }
            }
        }
    }

    @Test func newBrushControlsRoundTripThroughSetBrush() throws {
        let s = try K.session(40, 40)
        let patch: JSONValue = [
            "spacingEnabled": false,
            "shapeDynamics": ["tiltScale": 1.5, "brushProjection": true],
            "transfer": ["wetness": ["jitter": 0.3, "control": "penPressure"], "mix": ["jitter": 0.6, "minimum": 0.2]],
            "locks": ["shapeDynamics": true, "texture": true, "noise": true],
            "mixer": ["wet": 0.8, "load": 0.25, "mix": 0.4, "flow": 0.9, "sampleAllLayers": true],
        ]
        try s.execute("tools.setBrush", ["brush": patch])
        let b = s.tools.brush
        #expect(!b.spacingEnabled && b.shapeDynamics.brushProjection && b.shapeDynamics.tiltScale == 1.5)
        #expect(b.transfer.wetness.control == .penPressure)
        #expect(b.transfer.mix.jitter == 0.6 && b.transfer.mix.minimum == 0.2)
        #expect(b.locks.shapeDynamics && b.locks.texture && b.locks.noise && !b.locks.scattering)
        #expect(b.mixer.wet == 0.8 && b.mixer.load == 0.25 && b.mixer.mix == 0.4 && b.mixer.flow == 0.9 && b.mixer.sampleAllLayers)
        // brush.get reports them, and a fresh session gets the same brush from the reported JSON.
        let got = try s.execute("brush.get")
        #expect(got["spacingEnabled"] == false)
        #expect(got["shapeDynamics"]?["tiltScale"] == 1.5)
        #expect(got["shapeDynamics"]?["brushProjection"] == true)
        #expect(got["transfer"]?["wetness"]?["control"] == "penPressure")
        #expect(got["locks"]?["texture"] == true)
        #expect(got["mixer"]?["sampleAllLayers"] == true)
        #expect(got["mixer"]?["load"] == 0.25)
        let t = try K.session(40, 40)
        try t.execute("tools.setBrush", ["brush": got])
        #expect(t.tools.brush == s.tools.brush)
        // Locked sections survive picking a preset through the command.
        try s.execute("tools.setBrush", ["preset": "Chalk"])
        #expect(s.tools.brush.shapeDynamics.brushProjection && s.tools.brush.locks.texture)
        // Wrong types are errors and leave the brush alone.
        let before = s.tools.brush
        for bad: JSONValue in [["spacingEnabled": 3], ["locks": ["texture": "yes"]], ["mixer": ["wet": "wet"]], ["shapeDynamics": ["tiltScale": []]]] {
            #expect(throws: EngineError.self, "\(bad)") { try s.execute("tools.setBrush", ["brush": bad]) }
        }
        #expect(s.tools.brush == before)
    }

    @Test func mixerBrushUsesTheBrushMixerSettings() throws {
        let s = try K.session(200, 30)
        try s.execute("tools.setColors", ["foreground": "#ff0000"])
        try s.execute("tools.setBrush", ["brush": ["pressureSize": false, "spacing": 0.25, "mixer": ["wet": 0, "load": 0, "mix": 0]]])
        try s.execute("paint.mixerBrush", ["points": [[5, 15], [195, 15]], "size": 8])
        #expect(K.rgba(s, 10, 15).w > 0.95 && K.rgba(s, 190, 15).w < 0.5, "the brush's 0 % Load dries out")
        // A param still overrides the brush.
        try s.execute("paint.mixerBrush", ["points": [[5, 5], [195, 5]], "size": 8, "load": 100])
        #expect(K.rgba(s, 190, 5).w > 0.95)
    }

    @Test func coalescedSetBrushCallsJournalOncePerGesture() throws {
        let s = try K.session(20, 20)
        let n = s.journal.count
        for k in 1...10 {
            try s.execute("tools.setBrush", ["brush": ["opacity": .float(Float(k) / 20)], "coalesce": "bar:1"])
            try s.execute("brush.get")
        }
        try s.execute("tools.setBrush", ["brush": ["shapeDynamics": ["tiltScale": 0.5]], "coalesce": "bar:1"])
        #expect(s.journal.count == n + 1, "one gesture, one entry")
        let last = try #require(s.journal.last)
        #expect(last.id == "tools.setBrush")
        #expect(last.params["brush"] == ["opacity": 0.5, "shapeDynamics": ["tiltScale": 0.5]], "\(last.params)")
        // A new gesture is a new entry; so is an uncoalesced call.
        try s.execute("tools.setBrush", ["brush": ["flow": 0.5], "coalesce": "bar:2"])
        try s.execute("tools.setBrush", ["brush": ["flow": 0.4], "coalesce": "bar:2"])
        try s.execute("tools.setBrush", ["brush": ["size": 33]])
        #expect(s.journal.count == n + 3)
        // Another command in between ends the gesture.
        try s.execute("tools.setBrush", ["brush": ["size": 34], "coalesce": "bar:3"])
        try s.execute("paint.stroke", ["points": [[2, 2], [10, 10]]])
        try s.execute("tools.setBrush", ["brush": ["size": 35], "coalesce": "bar:3"])
        #expect(s.journal.count == n + 6)
        // Replay gives the same brush.
        let t = try K.session(20, 20)
        for inv in s.journal.dropFirst() { try t.execute(inv) }
        #expect(t.tools.brush == s.tools.brush)
    }

    /// A Scatter amount beyond the 1000 % maximum is rejected naming the value, before the session
    /// brush changes, by `tools.setBrush` and by a stroke's own brush patch (#977).
    @Test func outOfRangeScatterIsRejectedAndTheMaximumStillPaints() throws {
        func new() throws -> Session {
            let s = try K.session(32, 32, background: "white")
            try s.execute("layer.new.layer")
            return s
        }
        func scatter(_ j: Double) -> JSONValue { ["scattering": ["enabled": true, "bothAxes": true, "scatter": ["jitter": .number(j)]]] }
        func dual(_ j: Double) -> JSONValue { ["dualBrush": ["enabled": true, "bothAxes": true, "size": 6, "scatter": .number(j)]] }
        let stroke: JSONValue = ["points": [[10, 10]]]
        for (j, shown) in [(1e38, "1e38"), (10.01, "10.01"), (1e39, "inf"), (-1.0, "-1.0")] {
            for (patch, what) in [(scatter(j), "scatter"), (dual(j), "dual brush scatter")] {
                let s = try new()
                let before = s.tools.brush
                do {
                    try s.execute("tools.setBrush", ["brush": patch])
                    Issue.record("\(j): expected an error")
                } catch EngineError.badParams(_, let msg) {
                    #expect(msg.contains(what) && msg.contains(shown), "\(j): \(msg)")
                }
                #expect(s.tools.brush == before, "a rejected scatter must not change the session brush")
                let st = try #require(s.active)
                do {
                    _ = try BrushCommands.paintStroke(s, ["points": [[10, 10]], "brush": patch])
                    Issue.record("\(j): expected an error")
                } catch EngineError.badParams(_, let msg) {
                    #expect(msg.contains(shown), "\(j): \(msg)")
                }
                #expect(s.active?.doc == st.doc && s.active?.revision == st.revision)
            }
        }
        // The issue's repro, end to end: a stroke after the rejected update still paints normally.
        let s = try new()
        #expect(throws: EngineError.self) { try s.execute("tools.setBrush", ["brush": scatter(1e38)]) }
        try s.execute("paint.stroke", stroke)
        // The maximum (1000 %) is accepted and paints a finite, well-formed dab.
        for patch in [scatter(10), dual(10)] {
            let s = try new()
            try s.execute("tools.setBrush", ["brush": patch])
            let r = try s.execute("paint.stroke", stroke)
            let d = (r["damage"]?.arrayValue ?? []).compactMap(\.intValue)
            #expect(d.count == 4 && abs(d[0]) < 1000 && abs(d[1]) < 1000 && d[2] > 0 && d[3] > 0, "\(r)")
        }
        // Control: 200 % scatter paints where it did before the cap.
        let c = try new()
        try c.execute("tools.setBrush", ["brush": scatter(2)])
        let dmg = try c.execute("paint.stroke", stroke)
        #expect(dmg == ["damage": [17, 14, 23, 23]], "\(dmg)")
    }

    /// A live stroke over `pts` (pushed in chunks, as the canvas does) and its commit params.
    func liveAndCommit(_ s: Session, _ cmd: String, _ base: JSONValue, _ pts: [[Double]]) throws -> (BrushCommands.LiveStroke, JSONValue) {
        var live = try BrushCommands.LiveStroke.beginWith(s, cmd, base.setting("points", K.points([pts[0]])))
        for i in stride(from: 1, to: pts.count, by: 2) { try live.push(pts[i..<min(i + 2, pts.count)].map(K.sp)) }
        return (live, base.setting("points", K.points(pts)).setting("seed", .int(live.seed)))
    }

    @Test func aCommitTakesTheLiveStrokesPixelsAndTheyEqualAFreshRender() throws {
        let pts: [[Double]] = [[10, 50, 1], [60, 30, 0.7], [120, 60, 0.9], [180, 40, 0.4], [150, 80, 1]]
        let r = PixelRect(x: 0, y: 0, width: 200, height: 100)
        for (cmd, base): (String, JSONValue) in [
            ("paint.stroke", ["brush": ["size": 18, "hardness": 0.0, "flow": 0.5], "smoothing": 0.5, "target": "pixels"]),
            ("paint.stroke", ["preset": "Spatter", "smoothing": 0.0, "target": "pixels"]),
            ("paint.stroke", ["brush": ["size": 12], "erase": true, "target": "pixels"]),
            ("paint.pencil", ["smoothing": 0.0]),
        ] {
            let s = try K.session(200, 100)
            let (live, p) = try liveAndCommit(s, cmd, base, pts)
            let steps = s.active?.history.pastCount ?? 0
            try BrushCommands.offerLiveStroke(s, live)
            let res = try s.execute(cmd, p)
            BrushCommands.clearLiveStroke(s)
            #expect(res["fromLive"] == true, "\(cmd) \(base): the commit took the live pixels")
            #expect(s.active?.history.pastCount == steps + 1, "one undo step")
            // The journal's replay renders from scratch and must give the same pixels.
            let fresh = try K.session(200, 100)
            let fr = try fresh.execute(cmd, p)
            #expect(fr["fromLive"] == nil)
            #expect(K.samePixels(K.surface(s), K.surface(fresh), r), "\(cmd) \(base)")
            // Undo restores the pre-stroke pixels.
            s.undo()
            #expect(K.samePixels(K.surface(s), K.surface(try K.session(200, 100)), r))
        }
    }

    @Test func anOfferThatDoesNotMatchTheCommitIsIgnored() throws {
        let pts: [[Double]] = [[10, 50, 1], [60, 30, 0.7], [120, 60, 0.9]]
        let base: JSONValue = ["brush": ["size": 10], "smoothing": 0.0, "target": "pixels"]
        let r = PixelRect(x: 0, y: 0, width: 200, height: 100)
        // Different points.
        do {
            let s = try K.session(200, 100)
            let (live, p0) = try liveAndCommit(s, "paint.stroke", base, pts)
            let p = p0.setting("points", K.points([[10, 50, 1], [190, 90, 1]]))
            try BrushCommands.offerLiveStroke(s, live)
            let res = try s.execute("paint.stroke", p)
            BrushCommands.clearLiveStroke(s)
            #expect(res["fromLive"] == nil)
            let fresh = try K.session(200, 100)
            try fresh.execute("paint.stroke", p)
            #expect(K.samePixels(K.surface(s), K.surface(fresh), r))
        }
        // The document changed after the stroke began.
        do {
            let s = try K.session(200, 100)
            let (live, p) = try liveAndCommit(s, "paint.stroke", base, pts)
            try s.execute("layer.new.layer")
            try BrushCommands.offerLiveStroke(s, live)
            let res = try s.execute("paint.stroke", p)
            BrushCommands.clearLiveStroke(s)
            #expect(res["fromLive"] == nil, "a stale offer is never used")
        }
        // Another command leaves an offer untaken, and a later unrelated stroke can't use it.
        do {
            let s = try K.session(200, 100)
            let (live, _) = try liveAndCommit(s, "paint.stroke", base, pts)
            try BrushCommands.offerLiveStroke(s, live)
            let res = try s.execute("paint.stroke", base.setting("points", K.points([[5, 5, 1], [40, 5, 1]])))
            #expect(res["fromLive"] == nil)
        }
    }

    /// Photoshop's Clear painting mode (#3439): a Brush or Pencil stroke in `"mode": "clear"`
    /// erases with that brush, and History still names the tool rather than the Eraser.
    @Test func clearModeErasesWithTheBrushOrPencil() throws {
        for (cmd, label) in [("paint.stroke", "Brush Tool"), ("paint.pencil", "Pencil")] {
            let s = try K.session(40, 20)
            try K.fill(s, SIMD4(1, 0, 0, 1))
            try s.execute(cmd, ["points": [[2, 10], [38, 10]], "size": 6, "mode": "clear", "brush": ["hardness": 1.0]])
            #expect(K.rgba(s, 20, 10).w == 0, "\(cmd): cleared to transparency")
            #expect(K.rgba(s, 20, 2) == SIMD4(1, 0, 0, 1), "\(cmd): untouched pixels stay")
            #expect(s.active?.history.undoLabel == label, "\(cmd)")
        }
    }
}
