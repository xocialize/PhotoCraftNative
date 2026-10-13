// Port of photocraft-engine (crates/engine/src/fill_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: `timing_24mp` (an ignored benchmark). Adapted: the pattern case fills from a document
// pattern (photocraft's "Diagonal Lines" comes from the session library, another module's state).

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct FillCommandsTests {
    let cmd = "edit.fill"

    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 30, "background": "transparent"])
        return s
    }

    func px(_ s: Session, _ x: Int32, _ y: Int32) -> SIMD4<Float> {
        guard let st = s.active, let id = st.activeLayer, let surf = st.doc.layer(id)?.surface else { return SIMD4(-1, -1, -1, -1) }
        return surf.rgba(x: x, y: y)
    }

    func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
        (0..<4).allSatisfy { abs(a[$0] - b[$0]) < 1.5 / 255 }
    }

    @Test func everyConstantContents() throws {
        let s = try session()
        try s.execute("tools.setColors", ["foreground": [1, 0, 0, 1], "background": [0, 0, 1, 1]])
        let cases: [(String, SIMD4<Float>)] = [
            ("foreground", SIMD4(1, 0, 0, 1)), ("background", SIMD4(0, 0, 1, 1)), ("black", SIMD4(0, 0, 0, 1)),
            ("gray", SIMD4(128.0 / 255, 128.0 / 255, 128.0 / 255, 1)), ("white", SIMD4(1, 1, 1, 1)),
        ]
        for (c, want) in cases {
            try s.execute(cmd, ["contents": .string(c)])
            #expect(close(px(s, 5, 5), want), "\(c): \(px(s, 5, 5))")
        }
        try s.execute(cmd, ["contents": "color", "color": "#00ff00"])
        #expect(close(px(s, 5, 5), SIMD4(0, 1, 0, 1)))
        // The old form: a colour, or the foreground.
        try s.execute(cmd, ["color": "#ffff00"])
        #expect(close(px(s, 5, 5), SIMD4(1, 1, 0, 1)))
    }

    @Test func opacityModeAndPreserveTransparency() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 20, "height": 30])
        try s.execute(cmd, ["contents": "white"])
        try s.execute("select.deselect")
        // Preserve Transparency: the empty right half stays empty.
        try s.execute(cmd, ["contents": "black", "opacity": 50, "preserveTransparency": true])
        #expect(close(px(s, 5, 5), SIMD4(0.5, 0.5, 0.5, 1)), "\(px(s, 5, 5))")
        #expect(px(s, 30, 5).w == 0)
        // Multiply with white leaves the grey.
        try s.execute(cmd, ["contents": "white", "mode": "multiply", "preserveTransparency": true])
        #expect(close(px(s, 5, 5), SIMD4(0.5, 0.5, 0.5, 1)))
        // Without it, the transparent half is filled.
        try s.execute(cmd, ["contents": "white", "opacity": 100])
        #expect(px(s, 30, 5) == SIMD4(1, 1, 1, 1))
        // Dissolve paints whole pixels only.
        try s.execute(cmd, ["contents": "black", "mode": "dissolve", "opacity": 50])
        let st = try #require(s.active)
        let lid = try #require(st.activeLayer)
        let surf = try #require(st.doc.layer(lid)?.surface)
        var blacks = 0
        for x in Int32(0)..<40 { for y in Int32(0)..<30 where surf.rgba(x: x, y: y).x < 0.01 { blacks += 1 } }
        #expect(blacks > 300 && blacks < 900, "\(blacks)")
        #expect((Int32(0)..<40).allSatisfy { x in
            let v = surf.rgba(x: x, y: 3).x
            return v.isFinite && !(v >= 0.01 && v <= 0.99)
        })
    }

    @Test func historyPatternAndContentAware() throws {
        let s = try session()
        try s.execute(cmd, ["contents": "white"])
        try s.execute(cmd, ["contents": "black"])
        // History: back to state 1 (after the white fill).
        try s.execute(cmd, ["contents": "history", "state": 1])
        #expect(px(s, 5, 5) == SIMD4(1, 1, 1, 1))
        // The default source is the oldest state: the empty layer.
        try s.execute(cmd, ["contents": "history"])
        #expect(px(s, 5, 5).w == 0)
        #expect(throws: (any Error).self) { try s.execute(cmd, ["contents": "history", "state": 999]) }
        // A document pattern: a 4×4 red/blue checker.
        var tile = Surface(format: .rgba8)
        tile.fill(PixelRect(x: 0, y: 0, width: 4, height: 4), with: [1, 0, 0, 1])
        tile.fill(PixelRect(x: 0, y: 0, width: 2, height: 2), with: [0, 0, 1, 1])
        let pat = Pattern(name: "Checker", surface: tile, width: 4, height: 4)
        try s.edit("add pattern") { doc, _ in doc.patterns.append(pat) }
        let r = try s.execute(cmd, ["contents": "pattern", "pattern": "Checker"])
        #expect(r["pattern"]?.stringValue == pat.id)
        #expect(px(s, 5, 5).w > 0)
        #expect(close(px(s, 0, 0), SIMD4(0, 0, 1, 1)) && close(px(s, 2, 0), SIMD4(1, 0, 0, 1)), "\(px(s, 0, 0)) \(px(s, 2, 0))")
        // Content-Aware fills the hole from what is around it.
        try s.execute(cmd, ["contents": "color", "color": "#336699"])
        try s.execute("select.rect", ["x": 15, "y": 10, "width": 6, "height": 6])
        try s.execute(cmd, ["contents": "white"])
        try s.execute(cmd, ["contents": "contentAware", "colorAdaptation": false])
        let want = SIMD4<Float>(0x33 / 255.0, 0x66 / 255.0, 0x99 / 255.0, 1)
        #expect(close(px(s, 17, 12), want), "\(px(s, 17, 12))")
    }

    @Test func historyFillReadsASourceWhenItsPixelsWereLocked() throws {
        // Given a white layer locked in history state 1, then unlocked and filled red.
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16, "background": "white"])
        try s.execute("layer.lockLayers", ["pixels": true])
        try s.execute("layer.lockLayers", ["pixels": false])
        try s.execute(cmd, ["color": "#ff0000"])
        // When Fill reads the locked historical pixels, then it restores white; the historical
        // lock limits edits, not reads.
        try s.execute(cmd, ["contents": "history", "state": 1])
        #expect(close(px(s, 8, 8), SIMD4(1, 1, 1, 1)), "\(px(s, 8, 8))")
    }

    @Test func historyFillRefusesALockedDestinationWhenSourceIsUnlocked() throws {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16, "background": "white"])
        try s.execute(cmd, ["color": "#ff0000"])
        try s.execute("layer.lockLayers", ["pixels": true])
        #expect(throws: (any Error).self) { try s.execute(cmd, ["contents": "history", "state": 0]) }
        #expect(close(px(s, 8, 8), SIMD4(1, 0, 0, 1)), "\(px(s, 8, 8))")
    }

    @Test func badParamsAreErrors() throws {
        let s = try session()
        let bad: [JSONValue] = [
            ["contents": "plaid"], ["contents": 3], ["mode": "sideways"], ["mode": "passThrough"], ["opacity": "lots"],
            ["preserveTransparency": "yes"], ["contents": "contentAware"], ["contents": "pattern", "pattern": "no such pattern"],
            ["contents": "history", "state": -1], ["contents": "contentAware", "colorAdaptation": 1],
        ]
        for p in bad {
            #expect(throws: (any Error).self, "\(p.serialized())") { try s.execute(cmd, p) }
        }
        // Everything selected leaves nothing to sample from.
        try s.execute("select.all")
        #expect(throws: (any Error).self) { try s.execute(cmd, ["contents": "contentAware"]) }
        // Out-of-range opacity is clamped.
        try s.execute(cmd, ["contents": "white", "opacity": 1e300])
    }

    /// A session whose canvas is `size` and whose selection is the given (sparse) rectangles, as a
    /// loaded document can declare (#963).
    func hugeSelection(_ size: (Int, Int), _ rects: [PixelRect]) throws -> Session {
        let s = try session()
        try s.execute(cmd, ["contents": "color", "color": "#336699"])
        try s.updateActive { st in
            st.doc.size = PixelSize(width: size.0, height: size.1)
            var sel = Surface(format: .gray8)
            for r in rects { sel.fill(r, with: [1]) }
            st.doc.selection = sel
        }
        return s
    }

    /// Content-Aware fill on a selection whose extent overflows the sampling-window arithmetic
    /// (#963) returns the size error and leaves the document and history untouched.
    @Test func contentAwareHugeExtentIsAnError() throws {
        let edge = Int32(UInt32.max / 3)
        // As photocraft: the far rectangles sit in the last tile column/row before Int32.max.
        let mx = Int32.max, mn = Int32.min, tile = Int32(256), far = Int32.max - 2
        func r(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> PixelRect { PixelRect(x0: x0, y0: y0, x1: x1, y1: y1) }
        let cases: [(String, (Int, Int), [PixelRect])] = [
            ("issue repro", (2_000_000_000, 2_000_000_000), [r(0, 0, 8, 8), r(5_600_000 * tile, 0, 5_600_000 * tile + 8, 8)]),
            ("wide, just above", (2_000_000_000, 2_000_000_000), [r(0, 0, 1, 1), r(edge, 0, edge + 1, 1)]),
            ("tall, just above", (2_000_000_000, 2_000_000_000), [r(0, 0, 1, 1), r(0, edge, 1, edge + 1)]),
            ("wide, just below", (2_000_000_000, 2_000_000_000), [r(0, 0, 1, 1), r(edge - 1, 0, edge, 1)]),
            ("tall, just below", (2_000_000_000, 2_000_000_000), [r(0, 0, 1, 1), r(0, edge - 1, 1, edge)]),
            ("extreme coordinates", (Int(mx), Int(mx)), [r(mn, mn, mn + 1, mn + 1), r(0, 0, 1, 1), r(far, far, far + 1, far + 1)]),
            ("canvas beyond i32", (Int(UInt32.max), Int(UInt32.max)), [r(0, 0, 1, 1), r(far, 0, far + 1, 1)]),
        ]
        let want = SIMD4<Float>(0x33 / 255.0, 0x66 / 255.0, 0x99 / 255.0, 1)
        for (name, size, rects) in cases {
            let s = try hugeSelection(size, rects)
            let before = try #require(s.active?.doc)
            let past = s.active?.history.pastCount
            do {
                try s.execute(cmd, ["contents": "contentAware", "colorAdaptation": false])
                Issue.record("\(name): expected an error")
            } catch {
                let e = "\(error)"
                #expect(!e.contains("internal error"), "\(name): \(e)")
                if name != "canvas beyond i32" { #expect(e.contains("too large for Content-Aware fill"), "\(name): \(e)") }
            }
            #expect(s.active?.doc == before, "\(name): the document changed")
            #expect(s.active?.history.pastCount == past, "\(name): a history step was recorded")
            #expect(close(px(s, 5, 5), want), "\(name)")
        }
        // Control: an ordinary selection still fills from its surroundings.
        let s = try hugeSelection((40, 30), [r(15, 10, 21, 16)])
        try s.execute(cmd, ["contents": "white"])
        try s.execute(cmd, ["contents": "contentAware", "colorAdaptation": false])
        #expect(close(px(s, 17, 12), want), "\(px(s, 17, 12))")
    }

    /// Fill honours the targeted layer mask (#2456): the mask takes the colour's luminosity.
    @Test func fillsATargetedMask() throws {
        let s = try session()
        try s.execute("layer.layerMask.hideAll")
        try s.execute(cmd, ["contents": "white", "target": "mask"])
        let st = try #require(s.active)
        let lid = try #require(st.activeLayer)
        let m = try #require(st.doc.layer(lid)?.mask)
        #expect(m.value(x: 5, y: 5) == 1)
        #expect(px(s, 5, 5).w == 0, "the pixels are untouched")
    }
}
