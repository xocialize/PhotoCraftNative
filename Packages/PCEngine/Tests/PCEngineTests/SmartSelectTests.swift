// Port of photocraft-engine (crates/engine/src/smartselect_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: `object_selection_disc`, `select_subject_centred_object`,
// `select_subject_repeat_reuses_the_mask_until_pixels_change` and the Select Subject half of
// `empty_result_keeps_the_selection_in_every_mode` (Select › Subject and Object Selection are
// registered by PCIntelligence's bridge, not by this module). Also here: the check that every
// command this agent's ports register matches photocraft's catalogue.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct SmartSelectTests {
    /// photocraft-algo `segment::Rng` (deterministic xorshift64 + Box–Muller), for the test images.
    struct Rng {
        var s: UInt64
        init(_ seed: UInt64) { s = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
        mutating func nextU64() -> UInt64 {
            var x = s
            x ^= x << 13
            x ^= x >> 7
            x ^= x << 17
            s = x
            return x
        }
        mutating func f32() -> Float { Float(nextU64() >> 40) / Float(1 << 24) }
        mutating func normal() -> Float {
            let u = Float.maximum(f32(), 1e-7), v = f32()
            return (-2 * logf(u)).squareRoot() * cosf(2 * Float.pi * v)
        }
    }

    static func noiseField(_ w: Int, _ h: Int, _ seed: UInt64) -> [Float] {
        var rng = Rng(seed)
        return (0..<(w * h)).map { _ in rng.normal() }
    }

    /// A document whose background shows `px(x, y)` (RGB, 0–1), at the given depth.
    func session(_ w: Int, _ h: Int, _ depth: Int, _ px: (Int, Int) -> SIMD3<Float>) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h), "depth": .int(depth)])
        try s.edit("paint") { doc, _ in
            guard let id = doc.layers.first?.id else { throw EngineError.other("no background") }
            doc.withRaster(of: id) { bg in
                let n = bg.format.channels
                var data: [Float] = []
                data.reserveCapacity(w * h * n)
                for y in 0..<h {
                    for x in 0..<w {
                        let c = px(x, y)
                        for k in 0..<min(n, 3) { data.append(c[k]) }
                        if n == 4 { data.append(1) }
                    }
                }
                bg.writeRegion(PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)), data)
            }
        }
        return s
    }

    static func clamp01(_ c: SIMD3<Float>) -> SIMD3<Float> { c.clamped(lowerBound: .zero, upperBound: .one) }

    /// Warm textured left part (x < 60), cool right part.
    func twoRegions(_ depth: Int) throws -> Session {
        let nz = Self.noiseField(140, 100, 1)
        return try session(140, 100, depth) { x, y in
            let n = 0.04 * nz[y * 140 + x]
            return Self.clamp01(x < 60 ? SIMD3(0.8 + n, 0.5 + n, 0.3) : SIMD3(0.2, 0.35 + n, 0.6 + n))
        }
    }

    func cov(_ s: Session, _ x: Int32, _ y: Int32) -> Float { s.active?.doc.selection?.sampleChannel(x: x, y: y, 0) ?? 0 }

    // MARK: Quick Selection

    @Test func quickSelectionAddSubtractUndo() throws {
        for depth in [8, 16] {
            let s = try twoRegions(depth)
            let r = try s.execute("select.quick", ["points": [[20, 50], [35, 50]], "size": 8])
            #expect(r["selected"] == true)
            var (missed, leaked) = (0, 0)
            for y in stride(from: Int32(0), to: 100, by: 7) {
                for x in stride(from: Int32(0), to: 140, by: 3) {
                    let c = cov(s, x, y)
                    if x < 57 && c < 0.5 { missed += 1 }
                    if x > 62 && c >= 0.5 { leaked += 1 }
                }
            }
            #expect(missed == 0 && leaked == 0, "depth \(depth): \(missed) not selected, \(leaked) leaked")
            // A second stroke on the right adds it.
            try s.execute("select.quick", ["points": [[100, 50]], "size": 8])
            #expect(cov(s, 130, 90) >= 0.5 && cov(s, 10, 10) >= 0.5)
            // Subtract the left region again.
            try s.execute("select.quick", ["points": [[20, 50]], "size": 8, "mode": "subtract"])
            #expect(cov(s, 10, 10) < 0.5 && cov(s, 130, 90) >= 0.5)
            try s.execute("edit.undo")
            #expect(cov(s, 10, 10) >= 0.5)
            #expect(throws: EngineError.self) { try s.execute("select.quick", ["points": []]) }
        }
    }

    @Test func quickSelectionSubtractFromSelectAllAndEnhance() throws {
        let s = try twoRegions(8)
        try s.execute("select.all")
        try s.execute("select.quick", ["points": [[100, 30], [110, 70]], "size": 10, "mode": "subtract"])
        #expect(cov(s, 10, 50) >= 0.99)
        #expect(cov(s, 120, 20) < 0.01 && cov(s, 70, 90) < 0.01)
        try s.execute("select.deselect")
        try s.execute("select.quick", ["points": [[20, 50]], "size": 8, "enhanceEdge": true])
        #expect(cov(s, 10, 10) >= 0.5 && cov(s, 100, 50) < 0.5)
    }

    @Test func emptyResultKeepsTheSelectionInEveryMode() throws {
        // Finding nothing must never wipe the selection, whatever the mode: a missed Quick
        // Selection dab must not destroy the work.
        for m in ["add", "subtract", "replace"] {
            let s = try twoRegions(8)
            try s.execute("select.all")
            let n = s.active?.history.pastCount
            let r = try s.execute("select.quick", ["points": [[-5000, -5000]], "size": 8, "mode": .string(m)])
            #expect(r["changed"] == false, "mode \(m)")
            #expect(r["selected"] == true, "mode \(m)")
            #expect(cov(s, 10, 50) >= 0.99, "mode \(m): Select All survived an empty result")
            #expect(s.active?.history.pastCount == n, "mode \(m): no history step")
        }
    }

    // MARK: Select and Mask

    /// A vertical Gaussian-blurred edge at x = 40 (warm left, cool right) with the left half
    /// selected.
    func blurredEdgeSelected(_ depth: Int = 8) throws -> Session {
        let s = try session(80, 40, depth) { x, _ in
            let t = 1 / (1 + expf((Float(x) + 0.5 - 40) / 1.8))
            return SIMD3(0.9 * t + 0.1 * (1 - t), 0.8 * t + 0.2 * (1 - t), 0.2 * t + 0.6 * (1 - t))
        }
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 40, "height": 40])
        return s
    }

    func softCount(_ surf: Surface, _ y: Int32) -> Int {
        (Int32(0)..<80).filter { x in
            let v = surf.sampleChannel(x: x, y: y, 0)
            return v > 0.05 && v < 0.95
        }.count
    }

    @Test func refineEdgeOutputsAndUndo() throws {
        // Selection output: the hard edge becomes a soft matte following the blur.
        let s = try blurredEdgeSelected()
        #expect(s.isEnabled("select.refineEdge"))
        try s.execute("select.refineEdge", ["radius": 8])
        let sel = try #require(s.active?.doc.selection)
        #expect(softCount(sel, 20) >= 4, "selection edge not soft")
        #expect(sel.sampleChannel(x: 5, y: 20, 0) > 0.99 && sel.sampleChannel(x: 75, y: 20, 0) < 0.01)
        try s.execute("edit.undo")
        #expect(softCount(try #require(s.active?.doc.selection), 20) == 0)

        // Layer mask output.
        let layersBefore = try #require(s.active?.doc.layerCount)
        var r = try s.execute("select.refineEdge", ["radius": 8, "output": "layerMask"])
        var d = try #require(s.active)
        let maskLayer = LayerId(try #require(r["layer"]?.uint64Value))
        let l = try #require(d.doc.layer(maskLayer))
        let m = try #require(l.mask)
        #expect(softCount(m.surface, 20) >= 4)
        #expect(m.value(x: 5, y: 20) > 0.99 && m.value(x: 75, y: 20) < 0.01)
        #expect(d.doc.selection == nil)
        #expect(d.doc.layerCount == layersBefore)
        try s.execute("edit.undo")
        #expect(s.active?.doc.layers.first?.mask == nil)
        #expect(s.active?.doc.selection != nil)

        // New layer: pixels with the refined alpha; the source is hidden.
        r = try s.execute("select.refineEdge", ["radius": 8, "feather": 1, "output": "newLayer"])
        d = try #require(s.active)
        let nid = LayerId(try #require(r["layer"]?.uint64Value))
        #expect(d.activeLayer == nid)
        #expect(d.doc.layerCount == layersBefore + 1)
        let surf = try #require(d.doc.layer(nid)?.surface)
        #expect(surf.format.alpha)
        func a(_ x: Int32) -> Float { surf.pixel(x: x, y: 20)[3] }
        #expect(a(5) > 0.99 && a(75) == 0 && a(40) > 0.05 && a(40) < 0.95, "\(a(5)) \(a(40)) \(a(75))")
        #expect(d.doc.layers.first?.visible == false)
        try s.execute("edit.undo")
        #expect(s.active?.doc.layerCount == layersBefore)
        #expect(s.active?.doc.layers.first?.visible == true)

        // New layer with mask + decontamination (selection output upgrades to it).
        r = try s.execute("select.refineEdge", ["radius": 8, "decontaminate": true, "amount": 100])
        #expect(r["output"] == "newLayerWithMask")
        d = try #require(s.active)
        let decontaminated = LayerId(try #require(r["layer"]?.uint64Value))
        let nl = try #require(d.doc.layer(decontaminated))
        #expect(nl.mask != nil)
        let px = try #require(nl.surface).pixel(x: 41, y: 20)
        let orig = try #require(d.doc.layers.first?.surface).pixel(x: 41, y: 20)
        // The fringe colour moved towards the warm foreground (more red, less blue).
        #expect(px[0] > orig[0] + 0.05 && px[2] < orig[2] - 0.05, "\(px) vs \(orig)")
        try s.execute("edit.undo")
        #expect(throws: EngineError.self) { try s.execute("select.refineEdge", ["output": "bogus"]) }
        try s.execute("select.deselect")
        #expect(!s.isEnabled("select.refineEdge"))
    }

    /// Output To New Document (with or without a layer mask) opens a document like the source, at
    /// every depth, and leaves the source document as it was.
    @Test func refineEdgeOutputsToANewDocument() throws {
        for depth in [8, 16, 32] {
            let s = try blurredEdgeSelected(depth)
            try s.edit("profile") { doc, _ in doc.resolutionDpi = 300 }
            let before = try #require(s.active?.doc)
            var r = try s.execute("select.refineEdge", ["radius": 8, "output": "newDocument"])
            #expect(r["output"] == "newDocument" && r["document"] == 1, "depth \(depth)")
            #expect(s.activeIndex == 1)
            var nd = try #require(s.active?.doc)
            #expect(nd.size == before.size && nd.mode == before.mode && nd.depth == before.depth && nd.resolutionDpi == 300)
            #expect(nd.layers.count == 1)
            #expect(nd.selection == nil && nd.layers.first?.mask == nil)
            let surf = try #require(nd.layers.first?.surface)
            func a(_ x: Int32) -> Float { surf.pixel(x: x, y: 20)[3] }
            #expect(a(5) > 0.99 && a(75) == 0 && a(40) > 0.05 && a(40) < 0.95, "depth \(depth): \(a(5)) \(a(40)) \(a(75))")
            // The source is untouched: same layers, still visible, selection kept, no history step.
            let src = s.documents[0]
            #expect(src.doc.layers == before.layers)
            #expect(src.doc.selection == before.selection)
            #expect(src.history.undoLabel == "profile")

            // With a layer mask: full pixels, the refined matte as the mask.
            try s.execute("file.close", ["document": 1])
            r = try s.execute("select.refineEdge", ["radius": 8, "output": "newDocumentWithMask"])
            #expect(r["output"] == "newDocumentWithMask")
            nd = try #require(s.active?.doc)
            let l = try #require(nd.layers.first)
            #expect(l.surface?.pixel(x: 75, y: 20) == before.layers.first?.surface?.pixel(x: 75, y: 20), "depth \(depth)")
            let m = try #require(l.mask)
            #expect(softCount(m.surface, 20) >= 4, "depth \(depth)")
            #expect(m.value(x: 5, y: 20) > 0.99 && m.value(x: 75, y: 20) < 0.01, "depth \(depth)")
        }
    }

    @Test func refineEdgeShiftAndContrast() throws {
        let s = try blurredEdgeSelected()
        try s.execute("select.refineEdge", ["shiftEdge": 100])
        #expect(cov(s, 42, 20) > 0.99)
        try s.execute("edit.undo")
        try s.execute("select.refineEdge", ["feather": 8, "contrast": 100])
        #expect(cov(s, 38, 20) == 1 && cov(s, 42, 20) == 0)
    }

    /// The Refine Edge Brush adds strands beyond the radius band, at every depth, and rejects
    /// malformed strokes.
    @Test func refineEdgeBrushStrokes() throws {
        for depth in [8, 16, 32] {
            // Warm subject (x < 40) with warm strands every 4th column from x = 60, on blue.
            func strand(_ x: Int) -> Bool { x < 40 || ((60..<84).contains(x) && x % 4 == 0) }
            let s = try session(120, 40, depth) { x, _ in strand(x) ? SIMD3(0.9, 0.7, 0.2) : SIMD3(0.1, 0.3, 0.8) }
            try s.execute("select.rect", ["x": 0, "y": 0, "width": 40, "height": 40])
            let stroke: JSONValue = [["points": [[70, 5], [70, 35]], "size": 30]]
            try s.execute("select.refineEdge", ["radius": 4, "refineStrokes": stroke])
            #expect(cov(s, 64, 20) > 0.9 && cov(s, 72, 20) > 0.9, "depth \(depth): strands \(cov(s, 64, 20))")
            #expect(cov(s, 66, 20) < 0.1 && cov(s, 100, 20) < 0.01, "depth \(depth): background")
            try s.execute("edit.undo")
            // Subtract over the same place paints the refinement out again.
            let both: JSONValue = [["points": [[70, 5], [70, 35]], "size": 30], ["points": [[70, 5], [70, 35]], "size": 40, "mode": "subtract"]]
            try s.execute("select.refineEdge", ["radius": 4, "refineStrokes": both])
            #expect(cov(s, 64, 20) < 0.01, "depth \(depth)")
            try s.execute("edit.undo")
            let bad: [JSONValue] = [
                7,
                [5],
                [["points": []]],
                [["points": [[1, "x"]]]],
                [["points": [[1, 2, 3]]]],
                [["points": [[1, 2]], "size": 0]],
                [["points": [[1, 2]], "size": 1e9]],
                [["points": [[1, 2]], "mode": "xor"]],
                [["points": [[0, 0], [1e6, 1e6], [0, 0], [1e6, 1e6]], "size": 5000]],
            ]
            for b in bad {
                #expect(throws: EngineError.self, "\(b)") { try s.execute("select.refineEdge", ["refineStrokes": b]) }
            }
        }
    }

    @Test func refineEdgeWorksOnLayerMaskWithoutSelection() throws {
        let s = try blurredEdgeSelected()
        try s.execute("layer.layerMask.revealSelection")
        #expect(s.active?.doc.selection == nil)
        #expect(s.active?.doc.layers.first?.mask != nil)
        #expect(s.isEnabled("select.refineEdge"))
        let r = try s.execute("select.refineEdge", ["radius": 8])
        #expect(r["output"] == "layerMask")
        let m = try #require(s.active?.doc.layers.first?.mask)
        #expect(softCount(m.surface, 20) >= 4)
    }

    // MARK: Focus Area

    @Test func focusAreaCommand() throws {
        let nz = Self.noiseField(160, 100, 3)
        var blurred = [Float](repeating: 0, count: nz.count)
        for y in 0..<100 {
            for x in 0..<160 {
                var a: Float = 0
                for dy in -4...4 {
                    for dx in -4...4 { a += nz[min(max(y + dy, 0), 99) * 160 + min(max(x + dx, 0), 159)] }
                }
                blurred[y * 160 + x] = a / 81
            }
        }
        let s = try session(160, 100, 8) { x, y in
            let i = y * 160 + x
            let v = 0.5 + 0.15 * (x < 80 ? nz[i] : blurred[i] * 3)
            return Self.clamp01(SIMD3(repeating: v))
        }
        try s.execute("select.focusArea")
        #expect(cov(s, 30, 50) >= 0.5 && cov(s, 130, 50) < 0.5)
    }

    // MARK: Registration

    /// Not a photocraft test: every command this agent's ports register (smartselect_cmds,
    /// layer_menu_cmds Mask All Objects, retouch_cmds' content-aware tools, adjust_cmds
    /// Shadows/Highlights, frame_cmds) runs in this build and keeps photocraft's id, label, menu
    /// path, shortcut, params and module.
    @Test func idsMatchPhotocraftsCatalogue() throws {
        let ids = ["select.quick", "select.refineEdge", "select.focusArea", "layer.maskAllObjects", "paint.spotHealing", "paint.contentAwareMove",
                   "paint.patch", "image.adjustments.shadowsHighlights", "layer.new.frame", "layer.new.frameFromLayers"]
        let r = CommandRegistry.standard()
        for id in ids {
            let c = try #require(PhotocraftCatalog.byId[id], "\(id) is a photocraft command")
            let spec = try #require(r.spec(id), "\(id) is registered")
            #expect(spec.isAvailable, "\(id)")
            #expect(spec.module == c.module && spec.label == c.label && spec.menu == c.menu && spec.shortcut == c.shortcut, "\(id)")
            if !c.params.contains("(see photocraft source)") { #expect(spec.params == c.params, "\(id)") }
        }
        // Select › Subject and Object Selection are the PCIntelligence bridge's.
        var own = CommandRegistry()
        own.install(SmartSelectCommands.self)
        #expect(own.count == 3)
        #expect(!own.contains("select.subject") && !own.contains("select.object"))
        var frames = CommandRegistry()
        frames.install(FrameCommands.self)
        #expect(frames.count == 2)
    }
}
