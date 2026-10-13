// Content-Aware Fill, the Remove tool and Generative Fill on EraseKit's model-free tier (classical
// diffusion) over generated images: a red square on a smooth gradient, selected or brushed, filled
// from its surroundings. Pixels outside the hole must not change at any depth or colour model; the
// semantics (hole = coverage > 0, blend by coverage, grow 2 px, selection limits Remove, outputs
// current/new/duplicate) follow photocraft-engine's edit_menu_cmds and retouch_cmds/remove.
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import PCDocument
import PCFoundation
import PCHistory
import Synchronization
import Testing
@testable import PCIntelligence

@Suite struct FillTests {
    let ai = PCIntelligence()
    static let square = PixelRect(x: 100, y: 60, width: 40, height: 40)

    /// The gradient the red square hides.
    static func truth(_ x: Int, _ y: Int) -> SIMD4<Float> { SIMD4(Float(x) / 255, 0.5, Float(y) / 191, 1) }

    static func scene(depth: SampleType = .u8, mode: ColorMode = .rgb) -> Document {
        Fixture.document(width: 256, height: 192, depth: depth, mode: mode) { x, y in
            square.contains(x: Int32(x), y: Int32(y)) ? SIMD4(1, 0, 0, 1) : truth(x, y)
        }
    }

    /// Pixels of `s` outside `hole`, row by row.
    static func outside(_ s: Surface, _ hole: PixelRect, canvas: PixelRect) -> [Float] {
        var out: [Float] = []
        for y in canvas.y0..<canvas.y1 {
            for x in canvas.x0..<canvas.x1 where !hole.contains(x: x, y: y) { out += s.pixel(x: x, y: y) }
        }
        return out
    }

    @Test(arguments: [SampleType.u8, .u16, .f32])
    func contentAwareFillFillsTheSelectionFromItsSurroundings(depth: SampleType) async throws {
        var d = FillTests.scene(depth: depth)
        let hole = FillTests.square.outset(by: 2)
        d.selection = Fixture.selection(hole)
        let id = d.layers[0].id
        let out = try await ai.contentAwareFill(d, layer: id)
        #expect(out.receipt.tier == .classical && out.receipt.capability == .inpaint)
        #expect(out.layer == id && out.changedRect == hole)
        let after = try Fixture.applied(out.transaction, to: d)
        let s = try #require(after.layer(id)?.rasterSurface)
        // The red is gone and the fill follows the gradient.
        var err: Float = 0
        for y in hole.y0..<hole.y1 {
            for x in hole.x0..<hole.x1 {
                let p = s.readRGBA(PixelRect(x: Int(x), y: Int(y), width: 1, height: 1))[0]
                let t = FillTests.truth(Int(x), Int(y))
                err += abs(p.x - t.x) + abs(p.y - t.y) + abs(p.z - t.z)
                #expect(!(p.x > 0.8 && p.y < 0.2), "red left at \(x),\(y)")
            }
        }
        let mean = err / Float(hole.area * 3)
        #expect(mean < 0.03, "depth \(depth): mean error \(mean)")
        // Nothing outside the selection changed, at full depth.
        let before = try #require(d.layers[0].rasterSurface)
        #expect(FillTests.outside(s, hole, canvas: d.bounds) == FillTests.outside(before, hole, canvas: d.bounds))
        // One paintTiles step that undoes.
        var u = d
        let inverse = try out.transaction.apply(to: &u)
        try inverse.apply(to: &u)
        #expect(u == d)
    }

    @Test func softSelectionBlendsByCoverage() async throws {
        var d = FillTests.scene()
        let r = FillTests.square
        // Coverage 1 in the middle, 0.5 in a 4-px border (still on the red square).
        let values = (0..<r.area).map { i -> Float in
            let x = i % r.width, y = i / r.width
            return (x < 4 || y < 4 || x >= r.width - 4 || y >= r.height - 4) ? 0.5 : 1
        }
        d.selection = CoverageMask(rect: r, values: values).surface()
        let out = try await ai.contentAwareFill(d, layer: d.layers[0].id)
        let s = try #require(try Fixture.applied(out.transaction, to: d).layers[0].rasterSurface)
        let orig = d.layers[0].rasterSurface!
        // Fully covered: the fill (the gradient's green is 0.5). Half covered: halfway from red (green 0).
        let centre = s.readRGBA(PixelRect(x: 120, y: 80, width: 1, height: 1))[0]
        #expect(abs(centre.y - 0.5) < 0.06)
        let border = s.readRGBA(PixelRect(x: 101, y: 80, width: 1, height: 1))[0]
        #expect(abs(border.y - 0.25) < 0.06, "half-covered green \(border.y)")
        #expect(s.pixel(x: 99, y: 80) == orig.pixel(x: 99, y: 80), "outside the selection is untouched")
    }

    @Test func contentAwareFillOutputs() async throws {
        var d = FillTests.scene()
        let hole = FillTests.square.outset(by: 2)
        d.selection = Fixture.selection(hole)
        let bg = d.layers[0].id
        // New layer: only the fill, alpha = coverage; the target stays as it was.
        let new = try await ai.contentAwareFill(d, layer: bg, options: ContentAwareFillOptions(output: .new))
        let a = try Fixture.applied(new.transaction, to: d)
        #expect(a.layers.count == 2 && a.layers[0] == d.layers[0])
        let nl = try #require(a.layer(new.layer)?.rasterSurface)
        #expect(a.layer(new.layer)?.name == "Content-Aware Fill 1")
        #expect(nl.pixel(x: 120, y: 80).last == 1 && nl.pixel(x: 10, y: 10).last == 0)
        // Duplicate: a filled copy above, named as Photoshop names copies.
        let dup = try await ai.contentAwareFill(d, layer: bg, options: ContentAwareFillOptions(output: .duplicate))
        let b = try Fixture.applied(dup.transaction, to: d)
        #expect(b.layer(dup.layer)?.name == "Background copy")
        #expect(b.layers[0] == d.layers[0])
        // Rectangular sampling with a margin.
        let rect = try await ai.contentAwareFill(d, layer: bg, options: ContentAwareFillOptions(sampling: .rectangular(margin: 16)))
        #expect(rect.changedRect == hole)
    }

    @Test func cmykPixelsOutsideTheHoleSurviveExactly() async throws {
        var d = FillTests.scene(mode: .cmyk)
        let hole = FillTests.square.outset(by: 2)
        d.selection = Fixture.selection(hole)
        let out = try await ai.contentAwareFill(d, layer: d.layers[0].id)
        let s = try #require(try Fixture.applied(out.transaction, to: d).layers[0].rasterSurface)
        #expect(s.format.mode == .cmyk)
        #expect(FillTests.outside(s, hole, canvas: d.bounds) == FillTests.outside(d.layers[0].rasterSurface!, hole, canvas: d.bounds))
        let p = s.readRGBA(PixelRect(x: 120, y: 80, width: 1, height: 1))[0]
        #expect(!(p.x > 0.8 && p.y < 0.2), "the red square is filled")
    }

    @Test func samplingWindowMatchesPhotocraft() {
        let canvas = PixelRect(x: 0, y: 0, width: 1000, height: 800)
        // 4·√(50·50) = 200, centred on a small hole.
        #expect(PCIntelligence.samplingWindow(hole: PixelRect(x: 490, y: 390, width: 20, height: 20), canvas: canvas)
                    == PixelRect(x: 400, y: 300, width: 200, height: 200))
        // Slid inside the canvas at an edge.
        #expect(PCIntelligence.samplingWindow(hole: PixelRect(x: 0, y: 0, width: 10, height: 10), canvas: canvas)
                    == PixelRect(x: 0, y: 0, width: 200, height: 200))
        // Clipped where the canvas is smaller.
        #expect(PCIntelligence.samplingWindow(hole: PixelRect(x: 10, y: 10, width: 10, height: 10), canvas: PixelRect(x: 0, y: 0, width: 100, height: 100))
                    == PixelRect(x: 0, y: 0, width: 100, height: 100))
        #expect(PCIntelligence.samplingWindow(hole: .empty, canvas: canvas) == .empty)
    }

    // MARK: Remove tool

    @Test func removeFillsTheGrownStrokeLimitedByTheSelection() async throws {
        let d0 = FillTests.scene()
        let id = d0.layers[0].id
        let stroke = Fixture.selection(FillTests.square)
        let out = try await ai.remove(d0, layer: id, hole: stroke)
        #expect(out.receipt.tier == .classical)
        // The hole grew by 2 px, so the square's edge is gone too.
        #expect(out.changedRect.contains(FillTests.square.outset(by: 2)))
        let s = try #require(try Fixture.applied(out.transaction, to: d0).layers[0].rasterSurface)
        for (x, y) in [(120, 80), (100, 60), (139, 99)] {
            let p = s.readRGBA(PixelRect(x: x, y: y, width: 1, height: 1))[0]
            #expect(!(p.x > 0.8 && p.y < 0.2), "red left at \(x),\(y)")
        }
        #expect(s.pixel(x: 10, y: 10) == d0.layers[0].rasterSurface!.pixel(x: 10, y: 10))
        // A selection over the left half limits the change to it.
        var d1 = d0
        d1.selection = Fixture.selection(PixelRect(x: 0, y: 0, width: 120, height: 192))
        let half = try await ai.remove(d1, layer: id, hole: stroke)
        let h = try #require(try Fixture.applied(half.transaction, to: d1).layers[0].rasterSurface)
        #expect(h.pixel(x: 130, y: 80) == [1, 0, 0, 1], "outside the selection the object stays")
        let left = h.readRGBA(PixelRect(x: 110, y: 80, width: 1, height: 1))[0]
        #expect(!(left.x > 0.8 && left.y < 0.2))
        // Onto a new layer.
        let nl = try await ai.remove(d0, layer: id, hole: stroke, options: RemoveOptions(newLayer: true))
        let n = try Fixture.applied(nl.transaction, to: d0)
        #expect(n.layers.count == 2 && n.layers[0] == d0.layers[0])
    }

    @Test func removeOnATransparentLayerFillsAlphaToo() async throws {
        var d = FillTests.scene()
        var top = Layer.raster("Top", format: d.pixelFormat)
        top.withRaster { s in
            // Opaque grey on the left half, transparent on the right.
            s.fill(PixelRect(x: 0, y: 0, width: 128, height: 192), with: [0.5, 0.5, 0.5, 1])
            s.fill(PixelRect(x: 110, y: 80, width: 30, height: 30), with: [1, 0, 0, 1])
        }
        let id = d.insertAbove(nil, top)
        let out = try await ai.remove(d, layer: id, hole: Fixture.selection(PixelRect(x: 110, y: 80, width: 30, height: 30)))
        #expect(out.receipt.notes.contains("alpha filled classically"))
        let s = try #require(try Fixture.applied(out.transaction, to: d).layer(id)?.rasterSurface)
        #expect(s.pixel(x: 112, y: 95).last! > 0.5, "near the opaque side the fill is opaque")
        #expect(s.pixel(x: 138, y: 95).last! < 0.5, "near the transparent side it stays transparent")
    }

    // MARK: Refusals, progress, cancellation

    @Test func fillsRefuseWhatPhotocraftRefuses() async throws {
        let d = FillTests.scene()
        await #expect(throws: IntelligenceError.noSelection) { try await ai.contentAwareFill(d, layer: d.layers[0].id) }
        var locked = d
        locked.selection = Fixture.selection(FillTests.square)
        locked.updateLayer(locked.layers[0].id) { $0.locks.all = true }
        await #expect(throws: IntelligenceError.self) { try await ai.contentAwareFill(locked, layer: locked.layers[0].id) }
        var adj = d
        let aid = adj.insertAbove(nil, Layer(name: "Invert", content: .adjustment(.invert)))
        adj.selection = Fixture.selection(FillTests.square)
        await #expect(throws: IntelligenceError.self) { try await ai.contentAwareFill(adj, layer: aid) }
        await #expect(throws: IntelligenceError.self) { try await ai.remove(d, layer: d.layers[0].id, hole: Surface(format: .gray8)) }
        // Generative Fill has no model-free tier.
        var sel = d
        sel.selection = Fixture.selection(FillTests.square)
        do {
            _ = try await ai.generativeFill(sel, above: sel.layers[0].id, prompt: "a cat")
            Issue.record("Generative Fill ran without a provider")
        } catch IntelligenceError.unavailable(let c, _) {
            #expect(c == .generativeFill)
        }
    }

    @Test func progressIsMonotonicAndEndsAtOne() async throws {
        var d = FillTests.scene()
        d.selection = Fixture.selection(FillTests.square)
        let seen = Mutex<[IntelligenceProgress]>([])
        _ = try await ai.contentAwareFill(d, layer: d.layers[0].id) { p in seen.withLock { $0.append(p) } }
        let fractions = seen.withLock { $0.map(\.fraction) }
        #expect(fractions.count >= 3)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
    }

    @Test func cancellationStopsAProviderAndChangesNothing() async throws {
        let registry = ProviderRegistry()
        registry.register(inpaint: SlowInpaint())
        let slow = PCIntelligence(registry: registry)
        var d = FillTests.scene()
        d.selection = Fixture.selection(FillTests.square)
        let doc = d
        let task = Task { try await slow.contentAwareFill(doc, layer: doc.layers[0].id) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
