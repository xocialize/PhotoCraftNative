// Port of photocraft-engine (crates/engine/src/distort_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The `#[cfg(target_arch = "wasm32")]` assertion of `liquify_elapsed_time_is_wasm_safe` has no
// counterpart. Added: the ids match photocraft's metadata, and `applyToSurface` re-renders.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct DistortTests {
    let liquify = "filter.liquify", puppet = "edit.puppetWarp", puppetSmart = "layer.smartObjects.puppetWarp"
    let perspective = "edit.perspectiveWarp", perspectiveSmart = "layer.smartObjects.perspectiveWarp"

    /// 80×60 document, a new layer with a patterned 50×30 block at (10, 10).
    func session(_ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 80, "height": 60, "depth": .int(depth)])
        try s.execute("layer.new.layer")
        try s.edit("paint") { doc, a in
            guard let id = a else { throw EngineError.other("no layer") }
            doc.withRaster(of: id) { surf in
                for y in Int32(10)..<40 {
                    for x in Int32(10)..<60 {
                        let v = Float((x / 3 + y / 3) % 2)
                        surf.setPixel(x: x, y: y, [v, 1 - v, Float(x) / 80, 1])
                    }
                }
            }
        }
        return s
    }

    func active(_ s: Session) -> Layer? { s.active.flatMap { st in st.activeLayer.flatMap { st.doc.layer($0) } } }

    func activeSurface(_ s: Session) -> Surface { active(s)?.surface ?? Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: true)) }

    func worst(_ a: Surface, _ b: Surface, _ r: PixelRect) -> Float {
        zip(a.readRegion(r), b.readRegion(r)).map { abs($0 - $1) }.max() ?? 0
    }

    func worstPx(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }

    func smart(_ s: Session) -> SmartObject? {
        if case .smart(let sm)? = active(s)?.content { return sm }
        return nil
    }

    /// The active pixel layer as a smart object whose cache is its pixels (a source that can't be
    /// re-rendered: the filters run on the cache; SmartTests covers re-rendering).
    func makeSmart(_ s: Session) throws {
        let id = try #require(s.active?.activeLayer)
        try s.edit("smart") { doc, _ in
            doc.updateLayer(id) { l in
                guard let surf = l.surface else { return }
                l.content = .smart(SmartObject(source: .linked(path: ""), transform: .identity, cache: surf))
            }
        }
    }

    func rect(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> PixelRect { PixelRect(x0: x0, y0: y0, x1: x1, y1: y1) }

    func quad(_ q: [(Double, Double)]) -> JSONValue { .array(q.map { [.number($0.0), .number($0.1)] }) }

    @Test func liquifyIdentityStrokeDisplacementReconstructAndUndo() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let before = activeSurface(s)
            #expect(try s.execute(liquify)["changed"] == false)
            let zero = try s.execute(liquify, ["strokes": [["tool": "forwardWarp", "size": 30, "pressure": 0, "points": [[30, 25], [45, 25]]]]])
            #expect(zero["changed"] == false, "zero pressure is a no-op")
            let hist = s.active?.history.pastCount ?? 0
            let stroke: JSONValue = ["tool": "forwardWarp", "size": 30, "points": [[30, 25], [42, 25]]]
            let r = try s.execute(liquify, ["strokes": [stroke]])
            #expect(r["changed"] == true)
            #expect((r["maxDisplacement"]?.doubleValue ?? 0) > 4)
            #expect(s.active?.history.pastCount == hist + 1, "one history step")
            let after = activeSurface(s)
            // The pattern moved right: the output at (42, 25) shows what was a few px to the left.
            let d = (0..<12).map { k in worstPx(after.pixel(x: 42, y: 25), before.pixel(x: 42 - Int32(k), y: 25)) }
                .enumerated().min { $0.element < $1.element }?.offset ?? 0
            #expect(d >= 3, "\(depth): displaced by \(d)")
            #expect(after != before)
            // Reconstruct All in the same stroke list restores the original.
            let s2 = try session(depth)
            try s2.execute(liquify, ["strokes": [stroke, ["tool": "reconstructAll", "amount": 100]]])
            #expect(worst(activeSurface(s2), before, rect(0, 0, 80, 60)) <= 1 / 255)
            s.undo()
            #expect(activeSurface(s) == before)
            #expect(throws: (any Error).self) { try s.execute(liquify, ["strokes": [["tool": "melt", "points": [[1, 1]]]]]) }
            #expect(throws: (any Error).self) { try s.execute(liquify, ["strokes": [["points": [[1]]]]]) }
            #expect(throws: (any Error).self) { try s.execute(liquify, ["strokes": [], "meshSize": 0]) }
        }
    }

    @Test func liquifyRespectsTheSelection() throws {
        let s = try session(8)
        let before = activeSurface(s)
        _ = try? s.execute("select.all")
        try s.edit("sel") { doc, _ in
            var sel = Surface(format: PixelFormat(mode: .grayscale, sample: .u8, alpha: false))
            sel.fill(rect(0, 0, 35, 60), with: [1])
            doc.selection = sel
        }
        try s.execute(liquify, ["strokes": [["tool": "bloat", "size": 60, "points": [[35, 25], [35, 25], [35, 25], [35, 25]]]]])
        let after = activeSurface(s)
        #expect(after.readRegion(rect(36, 0, 80, 60)) == before.readRegion(rect(36, 0, 80, 60)), "unselected pixels stay")
        #expect(after.readRegion(rect(10, 10, 35, 40)) != before.readRegion(rect(10, 10, 35, 40)))
    }

    @Test func liquifyElapsedTimeIsReported() throws {
        let s = try session(8)
        let r = try s.execute(liquify, ["strokes": [["tool": "forwardWarp", "size": 30, "points": [[30, 25], [42, 25]]]]])
        #expect(r["changed"] == true)
        let ms = try #require(r["ms"]?.doubleValue)
        #expect(ms.isFinite && ms >= 0)
    }

    @Test func puppetIdentityTranslationAndUndo() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let before = activeSurface(s)
            #expect(try s.execute(puppet)["changed"] == false)
            #expect(try s.execute(puppet, ["pins": [["src": [20, 20], "dst": [20, 20]]]])["changed"] == false)
            try s.execute(puppet, ["pins": [["src": [30, 25], "dst": [36, 29]]], "mode": "rigid", "interpolation": "bilinear"])
            let after = activeSurface(s)
            #expect(after.contentBounds == rect(16, 14, 66, 44), "\(depth)")
            let moved = Resample.translateSurface(before, dx: 6, dy: 4)
            #expect(worst(after.convertedAny(to: before.format), moved, rect(16, 14, 66, 44)) <= 1 / 255, "\(depth)")
            s.undo()
            #expect(activeSurface(s) == before)
            #expect(throws: (any Error).self) { try s.execute(puppet, ["pins": [["src": [1, 1]]]]) }
            #expect(throws: (any Error).self) { try s.execute(puppet, ["pins": [], "mode": "wobbly"]) }
            #expect(throws: (any Error).self) { try s.execute(puppet, ["pins": [], "density": "lots"]) }
        }
    }

    @Test func puppetWithAnExpansionThatEmptiesTheMeshKeepsTheLayer() throws {
        // #951: a pinned warp over an empty mesh panicked in the solver; it must not erase the
        // layer either (the rasterizer keeps only pixels inside the mesh).
        let s = try session(8)
        let before = activeSurface(s)
        try s.execute(puppet, ["pins": [["src": [30, 25], "dst": [36, 29]]], "expansion": -200])
        #expect(activeSurface(s).readRegion(rect(0, 0, 80, 60)) == before.readRegion(rect(0, 0, 80, 60)))
    }

    @Test func puppetRefusesPinsThatStretchTheContentTooFar() throws {
        // #1019: a pin dragged to (2^20, 2^20) stretched the mesh over ~17.6 million tiles.
        let far: JSONValue = ["pins": [["src": [20, 20], "dst": [20, 20]], ["src": [50, 30], "dst": [1048576, 1048576]]]]
        let full = rect(0, 0, 80, 60)
        for depth in [8, 16, 32] {
            for selected in [false, true] {
                let s = try session(depth)
                if selected { try s.execute("select.rect", ["x": 10, "y": 10, "width": 30, "height": 30]) }
                let (before, past) = (activeSurface(s), s.active?.history.pastCount)
                do {
                    try s.execute(puppet, far)
                    Issue.record("\(depth) \(selected): no error")
                } catch {
                    #expect("\(error)".contains("too far"), "\(depth) \(selected): \(error)")
                }
                #expect(activeSurface(s).readRegion(full) == before.readRegion(full), "\(depth) \(selected): layer unchanged")
                #expect(s.active?.history.pastCount == past, "\(depth) \(selected): no history step")
            }
            // Controls: a rigid move still moves the content, and a pin 4000 px out (well inside
            // the budget) still warps.
            var s = try session(depth)
            try s.execute(puppet, ["pins": [["src": [20, 20], "dst": [30, 25]], ["src": [50, 30], "dst": [60, 35]]], "mode": "rigid"])
            #expect(activeSurface(s).contentBounds == rect(20, 15, 70, 45), "\(depth)")
            s = try session(depth)
            try s.execute(puppet, ["pins": [["src": [20, 20], "dst": [20, 20]], ["src": [50, 30], "dst": [4050, 4030]]]])
            #expect(activeSurface(s).contentBounds.x1 > 1000, "\(depth)")
        }
        // A smart object stores the filter; a warp too far to render leaves its pixels as they were.
        let s = try session(8)
        try makeSmart(s)
        let before = activeSurface(s)
        try s.execute(puppetSmart, far)
        #expect(smart(s)?.smartFilters.count == 1)
        #expect(activeSurface(s) == before)
    }

    @Test func puppetTwoPinsBendTheBlock() throws {
        let s = try session(8)
        // Hold the left end, lift the right end: the right side rises, the left stays.
        try s.execute(puppet, ["pins": [["src": [15, 25], "dst": [15, 25]], ["src": [55, 25], "dst": [55, 10]]], "mode": "normal", "density": "more"])
        let after = activeSurface(s)
        #expect(after.pixel(x: 12, y: 25)[3] > 0.5, "the held end stays")
        #expect(after.contentBounds.y0 < 6, "\(after.contentBounds)")
    }

    @Test func puppetMeshFollowsTheOutlineSoSeparateShapesMoveSeparately() throws {
        // #3105: two bars 24 px apart get two meshes, and the unpinned one stays put.
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 260, "height": 140, "depth": .int(depth)])
            try s.execute("layer.new.layer")
            try s.edit("paint") { doc, a in
                guard let id = a else { throw EngineError.other("no layer") }
                doc.withRaster(of: id) { surf in
                    for (y0, y1) in [(Int32(20), Int32(60)), (84, 120)] {
                        for y in y0..<y1 {
                            for x in Int32(10)..<250 {
                                let v = Float((x / 4 + y / 4) % 2)
                                surf.setPixel(x: x, y: y, [v, 1 - v, Float(y) / 140, 1])
                            }
                        }
                    }
                }
            }
            let before = activeSurface(s)
            try s.execute(puppet, ["pins": [["src": [130, 40], "dst": [130, 30]]], "density": "fewer", "expansion": 2, "interpolation": "bilinear"])
            let after = activeSurface(s).convertedAny(to: before.format)
            let still = worst(after, before, rect(0, 70, 260, 140))
            #expect(still <= 1 / 255, "\(depth): the unpinned bar stays (\(still))")
            #expect(worst(after, Resample.translateSurface(before, dx: 0, dy: -10), rect(0, 0, 260, 60)) <= 1 / 255, "\(depth): the pinned bar moves")
        }
    }

    @Test func perspectiveIdentityKnownHomographyAndMask() throws {
        let q = [(10.0, 10.0), (60.0, 10.0), (60.0, 40.0), (10.0, 40.0)]
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let before = activeSurface(s)
            let r = try s.execute(perspective, ["planes": [["src": quad(q), "dst": quad(q)]]])
            #expect(r["changed"] == false)
            // Shift the whole quad by (5, 3): a pure translation of the layer.
            let d = q.map { ($0.0 + 5, $0.1 + 3) }
            try s.execute(perspective, ["planes": [["src": quad(q), "dst": quad(d)]], "interpolation": "bilinear"])
            let after = activeSurface(s)
            #expect(after.contentBounds == rect(15, 13, 65, 43))
            #expect(worst(after.convertedAny(to: before.format), Resample.translateSurface(before, dx: 5, dy: 3), rect(15, 13, 65, 43)) <= 1 / 255, "\(depth)")
            s.undo()
            #expect(activeSurface(s) == before)
        }
        // A keystone: corners land where asked.
        let s = try session(8)
        let d = [(20.0, 10.0), (50.0, 10.0), (70.0, 50.0), (0.0, 50.0)]
        _ = try? s.execute("layer.layerMask.revealAll")
        try s.execute(perspective, ["planes": [["src": quad(q), "dst": quad(d)]]])
        let after = activeSurface(s)
        let b = after.contentBounds
        #expect(b.x0 <= 1 && b.x1 >= 69 && b.y1 >= 49 && b.y0 >= 9, "\(b)")
        #expect(after.pixel(x: 15, y: 12)[3] < 0.1, "the top narrowed")
        #expect(throws: (any Error).self) { try s.execute(perspective) }
        let zero = quad([(0, 0), (0, 0), (0, 0), (0, 0)])
        #expect(throws: (any Error).self) { try s.execute(perspective, ["planes": [["src": zero, "dst": zero]]]) }
        #expect(throws: (any Error).self) { try s.execute(perspective, ["planes": [["src": quad(q), "dst": quad(d)]], "straighten": "sideways"]) }
        // Malformed planes are refused, not trapped on.
        #expect(throws: (any Error).self) { try s.execute(perspective, ["planes": [["src": quad(Array(q.prefix(3))), "dst": quad(d)]]]) }
    }

    @Test func perspectiveWithASelectionMovesOnlyTheSelectedPartOfALinkedMask() throws {
        // #3083: the mask hides a stripe inside the selection (x 12..16) and one outside it (x 40..44).
        func maskAt(_ s: Session, _ x: Int32, _ y: Int32) -> Float { active(s)?.mask?.surface.sampleChannel(x: x, y: y, 0) ?? -1 }
        for selected in [true, false] {
            let s = try session(8)
            try s.execute("layer.layerMask.revealAll")
            try s.edit("mask") { doc, a in
                guard let id = a else { throw EngineError.other("no layer") }
                doc.updateLayer(id) { l in
                    l.mask?.surface.fill(rect(12, 10, 16, 40), with: [0])
                    l.mask?.surface.fill(rect(40, 10, 44, 40), with: [0])
                }
            }
            if selected { try s.execute("select.rect", ["x": 0, "y": 0, "width": 30, "height": 60]) }
            let q = [(0.0, 0.0), (30.0, 0.0), (30.0, 60.0), (0.0, 60.0)]
            let d = q.map { ($0.0 + 4, $0.1) }
            try s.execute(perspective, ["planes": [["src": quad(q), "dst": quad(d)]], "interpolation": "bilinear"])
            // The selected stripe moves with the pixels either way.
            #expect(maskAt(s, 17, 25) < 0.01 && maskAt(s, 13, 25) > 0.99, "selected=\(selected)")
            if selected {
                // The unselected stripe stays over the unselected pixels.
                #expect(maskAt(s, 43, 25) < 0.01 && maskAt(s, 47, 25) > 0.99)
                #expect(activeSurface(s).pixel(x: 43, y: 25)[3] == 1)
            } else {
                // Without a selection the whole mask moves with the layer.
                #expect(maskAt(s, 47, 25) < 0.01 && maskAt(s, 43, 25) > 0.99)
            }
        }
    }

    @Test func smartObjectsStoreDistortionsAsSmartFiltersLosslessly() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            try s.execute("layer.smartObjects.convertToSmartObject")
            let original = activeSurface(s)
            #expect(s.isEnabled(puppetSmart) && s.isEnabled(perspectiveSmart))
            try s.execute(liquify, ["strokes": [["tool": "twirlCw", "size": 40, "points": [[35, 25], [35, 25], [35, 25]]]]])
            let liq = activeSurface(s)
            #expect(liq != original)
            try s.execute(puppetSmart, ["pins": [["src": [30, 25], "dst": [34, 25]]], "mode": "rigid"])
            let q = [(10.0, 10.0), (60.0, 10.0), (60.0, 40.0), (10.0, 40.0)]
            try s.execute(perspectiveSmart, ["planes": [["src": quad(q), "dst": quad([(12, 10), (58, 10), (60, 40), (10, 40)])]]])
            #expect(smart(s)?.smartFilters.map(\.command) == [liquify, puppetSmart, perspectiveSmart])
            // Deleting the top two filters re-renders exactly the liquified state; deleting all
            // gives back the original pixels (nothing accumulated).
            try s.execute("layer.smartFilter.delete")
            try s.execute("layer.smartFilter.delete")
            #expect(activeSurface(s) == liq, "\(depth)")
            try s.execute("layer.smartFilter.delete")
            #expect(activeSurface(s) == original, "\(depth)")
            s.undo()
            #expect(activeSurface(s) == liq, "\(depth)")
        }
    }

    /// Not a photocraft test: an object whose source can't be re-rendered records its distortions
    /// on the cached pixels; the stored params drop `layer`, and undo steps back through them.
    @Test func smartObjectsWithoutASourceStoreDistortionsOnTheCache() throws {
        let s = try session(8)
        try makeSmart(s)
        let original = activeSurface(s)
        try s.execute(liquify, ["strokes": [["tool": "twirlCw", "size": 40, "points": [[35, 25], [35, 25], [35, 25]]]]])
        let liq = activeSurface(s)
        #expect(liq != original)
        try s.execute(puppetSmart, ["pins": [["src": [30, 25], "dst": [34, 25]]], "mode": "rigid"])
        #expect(smart(s)?.smartFilters.map(\.command) == [liquify, puppetSmart])
        #expect(smart(s)?.smartFilters.first?.params["layer"] == nil, "the stored params drop `layer`")
        s.undo()
        #expect(activeSurface(s) == liq)
        s.undo()
        #expect(activeSurface(s) == original)
    }

    @Test func enabledStates() throws {
        let s = try session(8)
        #expect(s.isEnabled(liquify) && s.isEnabled(puppet) && s.isEnabled(perspective))
        #expect(!s.isEnabled(puppetSmart) && !s.isEnabled(perspectiveSmart))
        try s.execute("layer.newAdjustmentLayer.invert")
        #expect(!s.isEnabled(puppet) && !s.isEnabled(perspective))
        let empty = Session()
        #expect(!empty.isEnabled(liquify))
        #expect(throws: (any Error).self) { try empty.execute(puppet, ["pins": []]) }
    }

    @Test func backgroundLayerIsFloatedByGeometricWarps() throws {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 30, "depth": 8])
        try s.execute(puppet, ["pins": [["src": [20, 15], "dst": [25, 15]]], "mode": "rigid"])
        let l = try #require(active(s))
        #expect(l.name == "Layer 0")
        let surf = try #require(l.surface)
        #expect(surf.format.alpha)
        #expect(surf.pixel(x: 2, y: 15)[3] < 0.01, "exposed area is transparent")
    }

    @Test func liquifyWithAFarOffStrokePointReturns() throws {
        // #937: the issue's request walked ~3.3e14 dab steps along a segment to (1e15, 0).
        for depth in [8, 16, 32] {
            var s = try session(depth)
            let r = try s.execute(liquify, ["strokes": [["tool": "forwardWarp", "size": 30, "points": [[0, 0], [1e15, 0]]]]])
            #expect(r["changed"] == true, "\(depth): the start of the stroke is on the canvas")
            s = try session(depth)
            let before = activeSurface(s)
            try s.execute(liquify, ["strokes": [["tool": "bloat", "size": 30, "points": [[5000, 5000], [1e15, 1e15]]]]])
            #expect(activeSurface(s).readRegion(rect(0, 0, 80, 60)) == before.readRegion(rect(0, 0, 80, 60)), "\(depth): off-canvas only")
        }
    }

    // MARK: Added

    /// The smart-filter hook re-renders each distortion from its stored params (nil for others).
    @Test func applyToSurfaceReRendersStoredParams() throws {
        let s = try session(8)
        let surf = activeSurface(s)
        let canvas = rect(0, 0, 80, 60)
        let q = [(10.0, 10.0), (60.0, 10.0), (60.0, 40.0), (10.0, 40.0)]
        let p: JSONValue = ["planes": [["src": quad(q), "dst": quad(q.map { ($0.0 + 5, $0.1 + 3) })]], "interpolation": "bilinear"]
        let out = try #require(DistortCommands.applyToSurface(perspectiveSmart, p, surf, canvas: canvas))
        #expect(out.contentBounds == rect(15, 13, 65, 43))
        #expect(DistortCommands.applyToSurface("filter.blur.gaussianBlur", ["radius": 2], surf, canvas: canvas) == nil)
        #expect(DistortCommands.applyToSurface(liquify, ["strokes": 3], surf, canvas: canvas) == nil, "bad stored params")
    }

    @Test func idsMatchPhotocraft() throws {
        let s = Session()
        let ids = [liquify, puppet, puppetSmart, perspective, perspectiveSmart]
        for id in ids {
            let spec = try #require(s.registry.spec(id))
            let pc = try #require(PhotocraftCatalog.byId[id])
            #expect(spec.isAvailable)
            #expect(spec.module == pc.module && spec.label == pc.label && spec.menu == pc.menu && spec.shortcut == pc.shortcut && spec.params == pc.params, "\(id)")
        }
        #expect(Set(PhotocraftCatalog.commands.filter { $0.module == "distort_cmds" }.map(\.id)) == Set(ids))
    }
}
