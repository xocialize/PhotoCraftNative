// Select ▸ Subject, Object Selection, the Object Finder hover preview and Remove Background on their
// model-free tier (Apple Vision through ExtractKit and MaskKit's seam), on generated images: a disc
// on a flat background (one subject), two discs (two objects), and a flat image (nothing). The
// expectations mirror photocraft-engine's smartselect_cmds and cutout_cmds tests. MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import PCDocument
import PCFoundation
import PCHistory
import Synchronization
import Testing
@testable import PCIntelligence

@Suite(.enabled(if: VisionProbe.detectsDisc, "Apple Vision found no subject in the generated disc on this machine (headless or no Vision); the model-free selection tier cannot be exercised here"))
struct SelectionTests {
    let ai = PCIntelligence()

    @Test(arguments: [SampleType.u8, .u16, .f32])
    func selectSubjectFindsTheDiscAtEveryDepth(depth: SampleType) async throws {
        // Off-centre, so a flipped or transposed mask would fail.
        let d = Fixture.disc(cx: 180, cy: 140, r: 95, depth: depth)
        let out = try await ai.selectSubject(d)
        #expect(out.changed)
        #expect(out.receipt.tier == .vision && out.receipt.capability == .subjectMatte)
        let iou = Fixture.iou(out.selection, width: 512, height: 384) { Fixture.inside($0, $1, 180, 140, 95) }
        #expect(iou > 0.9, "depth \(depth): IoU \(iou)")
        let sel = try #require(out.selection)
        #expect(sel.format == .gray8)
        #expect(sel.pixel(x: 2, y: 2) == [0], "the background corner is not selected")
        #expect(sel.pixel(x: 180, y: 140)[0] > 0.9)
        #expect(out.bounds.intersect(PixelRect(x: 80, y: 40, width: 200, height: 200)) == out.bounds)
        // One undoable step that sets the selection.
        let applied = try Fixture.applied(out.transaction, to: d)
        #expect(applied.selection == out.selection)
        #expect(out.transaction?.label == "Select Subject")
    }

    @Test func selectSubjectOnAFlatImageChangesNothing() async throws {
        var d = Fixture.document(width: 128, height: 96) { _, _ in SIMD4(0.5, 0.5, 0.5, 1) }
        d.selection = Fixture.selection(PixelRect(x: 10, y: 10, width: 20, height: 20))
        let out = try await ai.selectSubject(d)
        #expect(!out.changed)
        #expect(out.transaction == nil)
        #expect(out.selection == d.selection, "finding nothing never destroys the selection")
    }

    @Test func selectSubjectCombinesByMode() async throws {
        var d = Fixture.disc()
        d.selection = Fixture.selection(PixelRect(x: 0, y: 0, width: 40, height: 40))
        let add = try await ai.selectSubject(d, options: SubjectOptions(mode: .add))
        #expect(add.selection?.pixel(x: 5, y: 5) == [1], "add keeps the old selection")
        #expect((add.selection?.pixel(x: 256, y: 192)[0] ?? 0) > 0.9)
        let inter = try await ai.selectSubject(d, options: SubjectOptions(mode: .intersect))
        #expect(inter.selection == nil, "the disc and the corner square don't overlap")
        // The transaction of an emptying intersect clears the selection.
        #expect(try Fixture.applied(inter.transaction, to: d).selection == nil)
    }

    @Test func compositeSourceNeedsACompositorWithSeveralLayers() async throws {
        var d = Fixture.disc()
        d.insertAbove(nil, Layer.raster("Empty", format: d.pixelFormat))
        await #expect(throws: IntelligenceError.self) { try await ai.selectSubject(d, source: .composite) }
        // The layer source and an injected compositor both work.
        let byLayer = try await ai.selectSubject(d, source: .layer(d.layers[0].id))
        #expect(byLayer.changed)
        let calls = Mutex(0)
        let composited = PCIntelligence(compositor: { doc, _ in
            calls.withLock { $0 += 1 }
            return doc.layers[0].surface!
        })
        #expect(try await composited.selectSubject(d).changed)
        #expect(calls.withLock { $0 } == 1)
    }

    // MARK: Object Selection

    @Test func clickSelectsTheObjectUnderIt() async throws {
        let d = Fixture.twoDiscs()
        let left = try await ai.selectObject(d, prompt: .click(x: 120, y: 180))
        #expect(left.changed && left.receipt.tier == .vision)
        #expect(Fixture.iou(left.selection, width: 512, height: 384) { Fixture.inside($0, $1, 120, 180, 80) } > 0.85)
        #expect(left.selection?.pixel(x: 375, y: 195) == [0], "the other disc stays unselected")
        let right = try await ai.selectObject(d, prompt: .box(x: 290, y: 110, width: 170, height: 170))
        #expect(Fixture.iou(right.selection, width: 512, height: 384) { Fixture.inside($0, $1, 375, 195, 75) } > 0.85)
        // Both, then subtract one with an exclude click.
        let both = try await ai.selectObject(d, prompt: ObjectPrompt(points: [ObjectPoint(x: 120, y: 180), ObjectPoint(x: 375, y: 195)]))
        #expect((both.selection?.pixel(x: 120, y: 180)[0] ?? 0) > 0.9 && (both.selection?.pixel(x: 375, y: 195)[0] ?? 0) > 0.9)
        let minus = try await ai.selectObject(d, prompt: ObjectPrompt(points: [ObjectPoint(x: 120, y: 180), ObjectPoint(x: 375, y: 195),
                                                                                ObjectPoint(x: 375, y: 195, include: false)]))
        #expect(minus.selection?.pixel(x: 375, y: 195) == [0])
    }

    @Test func clickOnTheBackgroundFindsNothing() async throws {
        let d = Fixture.twoDiscs()
        let out = try await ai.selectObject(d, prompt: .click(x: 10, y: 10))
        #expect(!out.changed && out.transaction == nil)
        await #expect(throws: IntelligenceError.self) { try await ai.selectObject(d, prompt: ObjectPrompt()) }
    }

    @Test func objectFinderHoverPreview() async throws {
        let d = Fixture.twoDiscs()
        let finder = try await ai.objectFinder(d)
        #expect(finder.objects.count == 2)
        #expect(finder.receipt.tier == .vision)
        let hover = try #require(finder.object(atX: 120, y: 180))
        #expect(hover.bounds.contains(x: 120, y: 180))
        #expect(finder.object(atX: 375, y: 195)?.index != hover.index)
        #expect(finder.object(atX: 5, y: 5) == nil)
        #expect(finder.object(atX: -50, y: 9999) == nil)
        // Clicking in auto-select mode selects the highlighted object.
        let click = finder.select(hover, existing: nil)
        #expect(Fixture.iou(click.selection, width: 512, height: 384) { Fixture.inside($0, $1, 120, 180, 80) } > 0.85)
        #expect(click.transaction?.label == "Object Selection")
    }

    // MARK: Remove Background

    @Test(arguments: [SampleType.u8, .u16, .f32])
    func removeBackgroundMasksTheSubjectAndUndoes(depth: SampleType) async throws {
        let d = Fixture.disc(depth: depth)
        let id = d.layers[0].id
        let before = d.layers[0].rasterSurface!
        let out = try await ai.removeBackground(d, layer: id)
        let after = try Fixture.applied(out.transaction, to: d)
        let l = try #require(after.layer(id))
        #expect(l.name == "Layer 0" && !l.locks.transparency && !l.locks.position, "the Background became a layer")
        let mask = try #require(l.mask)
        #expect(mask.value(x: 256, y: 192) > 0.9 && mask.value(x: 2, y: 2) < 0.1)
        #expect(l.rasterSurface == before, "non-destructive: pixels untouched")
        #expect(after.selection == nil)
        #expect(out.receipt.tier == .vision)
        // Undo through the inverse transaction.
        var d2 = d
        let inverse = try out.transaction.apply(to: &d2)
        #expect(d2.layer(id)?.mask != nil)
        try inverse.apply(to: &d2)
        #expect(d2 == d)
    }

    /// A smart object stays one (AB-T-0309): its rendered placement is sampled and only its mask is written.
    @Test func removeBackgroundMasksASmartObjectWithoutRasterizingIt() async throws {
        let disc = Fixture.disc()
        let rendered = try #require(disc.layers[0].rasterSurface)
        var d = Fixture.document(width: 512, height: 384) { _, _ in SIMD4(1, 1, 1, 1) }
        let so = SmartObject(source: .embedded(fileName: "disc.png", bytes: [1, 2, 3]), transform: .identity, cache: rendered)
        let id = d.insertAbove(nil, Layer(name: "disc", content: .smart(so)))
        let out = try await ai.removeBackground(d, layer: id)
        let after = try Fixture.applied(out.transaction, to: d)
        let l = try #require(after.layer(id))
        guard case .smart(let kept) = l.content else { Issue.record("still a smart object"); return }
        #expect(kept == so)
        let mask = try #require(l.mask)
        #expect(mask.value(x: 256, y: 192) > 0.9 && mask.value(x: 2, y: 2) < 0.1)
        #expect(after.layers[0] == d.layers[0], "the Background below is untouched")
        // Type, shapes, fills and adjustments are still refused.
        var adj = d
        let aid = adj.insertAbove(nil, Layer(name: "Invert", content: .adjustment(.invert)))
        await #expect(throws: IntelligenceError.self) { try await ai.removeBackground(adj, layer: aid) }
    }

    @Test func removeBackgroundRefusesWhatPhotocraftRefuses() async throws {
        let flat = Fixture.document(width: 64, height: 64) { _, _ in SIMD4(0.5, 0.5, 0.5, 1) }
        await #expect(throws: IntelligenceError.nothingFound("no subject found")) {
            try await ai.removeBackground(flat, layer: flat.layers[0].id)
        }
        var locked = Fixture.disc()
        locked.updateLayer(locked.layers[0].id) { $0.locks.pixels = true }
        await #expect(throws: IntelligenceError.self) { try await ai.removeBackground(locked, layer: locked.layers[0].id) }
        await #expect(throws: IntelligenceError.noLayer(999_999)) { try await ai.removeBackground(locked, layer: LayerId(999_999)) }
    }
}
