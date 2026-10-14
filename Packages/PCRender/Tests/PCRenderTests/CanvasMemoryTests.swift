// New: the canvas's GPU memory declaration and shrink ladder (CanvasMemory.swift; AB-A-0169 §2).

import Foundation
import Metal
import PCDocument
import PCFoundation
import Testing
@testable import PCRender

@Suite(.serialized) struct CanvasMemoryTests {
    static let doc = BenchmarkDocuments.realistic20(size: 1024)
    static let viewport = PixelRect(x: 0, y: 0, width: 512, height: 512)

    struct Rig {
        let metal: MetalCompositor
        let gpu: DocumentCompositor
        let canvas: CanvasRenderer

        /// An off-view render of the whole document (as an export band would), then `viewport` shown.
        func prime(_ viewport: PixelRect = CanvasMemoryTests.viewport) throws {
            metal.pressureCleared()
            let all = gpu.plan(CanvasMemoryTests.doc, region: CanvasMemoryTests.doc.bounds)
            _ = try metal.render(all.plan, region: CanvasMemoryTests.doc.bounds, source: all.source)
            try show(viewport)
        }

        func show(_ region: PixelRect) throws {
            let p = gpu.plan(CanvasMemoryTests.doc, region: region)
            try canvas.show(p.plan, region: region, source: p.source, compositor: metal)
        }
    }

    /// 512² pages: the 512² viewport is one page cell of 4.
    static func rig(chunk: Int = 512) -> Rig? {
        guard let metal = try? MetalCompositor(chunkSize: chunk), let canvas = try? CanvasRenderer() else { return nil }
        metal.lowFootprintCell = 256
        return Rig(metal: metal, gpu: DocumentCompositor(rasterizer: DT.rasterizer, backend: .metal, metal: metal), canvas: canvas)
    }

    @Test func footprintAddsUpTheCaches() throws {
        guard let r = Self.rig() else { return }
        try r.prime()
        let f = r.metal.footprint
        #expect(f == r.metal.lastFootprint)
        #expect(f.pages > 0 && f.effectMaps > 0 && f.poolHeaps > 0)
        #expect(f.persistent == f.pages + f.leafImages + f.gatherPages + f.effectMaps + f.masks + f.patterns + f.poolHeaps)
        #expect(f.visiblePages > 0 && f.visiblePages < f.pages + f.leafImages, "the viewport uses a quarter of the pages")
        #expect(f.sheddableOnRun == f.persistent - f.visiblePages - f.visibleEffects)
        // Allocation sizes against the logical sizes eviction counts (alignment only).
        let logical = r.metal.residency.residentBytes, allocated = f.pages + f.leafImages + f.gatherPages
        #expect(abs(Double(allocated) / Double(logical) - 1) < 0.05, "\(allocated) vs \(logical)")
        // The canvas holds the shown composite (rgba16Float) and its reduction chain.
        let d = r.canvas.footprint
        #expect(d.composite >= Self.viewport.area * 8 && Double(d.composite) < Double(Self.viewport.area * 8) * 1.05)
        #expect(d.levels > 0 && d.levels < d.composite / 2)
        // The next show allocates a new output: at least that is transient.
        #expect(f.transient >= Self.viewport.area * 8)
    }

    @Test func eachLevelFreesWhatItReports() throws {
        guard let r = Self.rig() else { return }
        for level in ReliefLevel.allCases {
            try r.prime()
            let before = r.metal.footprint
            let freed = r.metal.relieve(level)
            let after = r.metal.footprint
            #expect(before.declared - after.declared == freed, "\(level)")
            #expect(after.poolHeaps == 0 && after.patterns == 0, "\(level)")
            if level >= .offscreen {
                #expect(after.pages + after.leafImages == after.visiblePages && after.gatherPages == 0, "\(level)")
                #expect(after.visiblePages == before.visiblePages, "\(level)")
            }
            if level >= .offscreen && level < .effects {
                #expect(after.effectMaps + after.masks == after.visibleEffects && after.visibleEffects == before.visibleEffects, "\(level)")
            }
            if level >= .lowFootprint { #expect(r.metal.limits.renderCell == 256, "\(level)") }
            if level == .effects { #expect(after.effectMaps == 0 && after.masks == 0) }
        }
        r.metal.pressureCleared()
        #expect(r.metal.limits.renderCell == 512)
    }

    @Test func aRunLevelShrinkKeepsWhatTheNextFrameUses() throws {
        guard let r = Self.rig() else { return }
        try r.prime()
        let before = r.metal.footprint
        let relief = r.metal.relieve(requested: .max, reason: .run)
        #expect(relief.rungs.map(\.level) == [.scratch, .patterns, .offscreen])
        #expect(relief.freed > 0 && relief.freed == before.declared - relief.footprint.declared)
        #expect(relief.footprint.visiblePages == before.visiblePages && relief.footprint.visibleEffects == before.visibleEffects)
        #expect(relief.footprint.sheddableOnRun == 0)
        // The next frame uploads no tile and rebuilds no effect map.
        let uploads = r.metal.tilesUploaded, built = r.metal.mapBytesAllocated
        try r.show(Self.viewport)
        #expect(r.metal.tilesUploaded == uploads)
        #expect(r.metal.mapBytesAllocated == built)
    }

    @Test func theLadderStopsOnceTheRequestIsMet() throws {
        guard let r = Self.rig() else { return }
        try r.prime()
        let relief = r.metal.relieve(requested: 1, reason: .admission)
        #expect(relief.freed >= 1)
        #expect(relief.rungs.dropLast().reduce(0) { $0 + $1.freed } < 1, "\(relief.rungs)")
        #expect(relief.rungs.count < ReliefLevel.allCases.count)
    }

    @Test func theLadderSkipsVisibleEffectsWhenTheirRebuildCostsMore() throws {
        guard let r = Self.rig() else { return }
        r.metal.pressureCleared()
        try r.show(Self.doc.bounds)
        let relief = r.metal.relieve(requested: .max, reason: .admission)
        #expect(relief.rungs.last?.level == .effects && relief.rungs.last?.freed == 0)
        #expect(relief.footprint.effectMaps > 0 && relief.footprint.effectMaps + relief.footprint.masks == relief.footprint.visibleEffects)
        // Asked directly, the rung sheds them, and the transient counts their rebuild.
        let before = r.metal.footprint
        let freed = r.metal.relieve(.effects)
        let after = r.metal.footprint
        #expect(after.effectMaps == 0 && after.masks == 0)
        #expect(freed == before.declared - after.declared && freed <= 0)
        #expect(after.transient > before.transient)
    }

    /// AB-T-0260: the declaration falls under the lock, but what a shrink drops is released after
    /// it, on the release queue (Metal's deallocation, ~9 ms per GB, would hold the lock).
    @Test func whatAShrinkDropsIsReleasedAfterTheLock() throws {
        guard let r = Self.rig() else { return }
        try r.prime()
        final class Weak { weak var object: AnyObject?; init(_ o: AnyObject) { object = o } }
        let held = r.metal.fxCache.values.map { Weak($0.maps) } + r.metal.maskCache.values.map { Weak($0.mask) }
        #expect(!held.isEmpty)
        // Hold the release queue: the shrink must neither wait for it nor release on this thread.
        let gate = DispatchSemaphore(value: 0)
        MetalCompositor.releases.async { gate.wait() }
        let before = r.metal.footprint
        let freed = r.metal.relieve(.effects)
        #expect(freed == before.declared - r.metal.footprint.declared)
        #expect(r.metal.fxCache.isEmpty && r.metal.maskCache.isEmpty && r.metal.footprint.poolHeaps == 0)
        #expect(held.allSatisfy { $0.object != nil }, "released before the release queue ran")
        gate.signal()
        r.metal.waitForReleases()
        #expect(held.allSatisfy { $0.object == nil }, "still held after the release queue ran")
    }

    @Test func lowFootprintCellsRenderTheSamePixels() throws {
        guard let r = Self.rig(chunk: 1024) else { return }
        let p = r.gpu.plan(Self.doc, region: Self.doc.bounds)
        for precision in [AccumulatorPrecision.float, .automatic] {
            r.metal.pressureCleared()
            r.metal.precision = precision
            let normal = try r.metal.renderBuffer(p.plan, region: Self.doc.bounds, source: p.source)
            r.metal.relieve(.lowFootprint)
            #expect(r.metal.limits.renderCell == 256)
            let low = try r.metal.renderBuffer(p.plan, region: Self.doc.bounds, source: p.source)
            #expect(low == normal, "\(precision)")
        }
    }

    @Test func withoutABudgetTheCapsAreTodays() throws {
        guard let m = try? MetalCompositor() else { return }
        #expect(m.memoryBudget == nil)
        #expect(m.limits == CacheLimits(residency: 4 << 30, effects: 1536 << 20, idleHeaps: nil, renderCell: 2048))
        #expect(m.residency.cap == nil && m.residency.protected.isEmpty)
        m.memoryBudget = 16 << 30
        #expect(m.limits == CacheLimits(residency: 4 << 30, effects: Int(Double(16 << 30) * 0.1), idleHeaps: 2, renderCell: 2048))
        #expect(m.residency.cap == 4 << 30)
        m.memoryBudget = nil
        #expect(m.limits == CacheLimits(residency: 4 << 30, effects: 1536 << 20, idleHeaps: nil, renderCell: 2048))
        #expect(m.residency.cap == nil)
        // Every heap is kept after a render, as before.
        guard let r = Self.rig() else { return }
        try r.prime()
        let heaps = r.metal.pool.allocatedBytes
        try r.show(Self.viewport)
        #expect(r.metal.pool.allocatedBytes == heaps)
    }

    @Test func aBudgetCapEvictsWhatIsOffScreenButNeverWhatIsVisible() throws {
        guard let r = Self.rig() else { return }
        try r.prime()
        let visible = r.metal.footprint.visiblePages
        r.metal.memoryBudget = visible * 2   // residency cap: half the visible pages
        try r.show(Self.viewport)
        let f = r.metal.footprint
        #expect(f.visiblePages == visible)
        #expect(f.pages + f.leafImages == visible, "everything off-screen evicted, the visible pages kept over the cap")
        #expect(r.metal.limits.idleHeaps == 2)
    }

    @Test func afterAnOffscreenShrinkPanningEvictsInsteadOfGrowing() throws {
        guard let r = Self.rig() else { return }
        try r.prime()
        r.metal.relieve(.offscreen)
        let cap = r.metal.limits.residency
        #expect(cap == r.metal.residentBytes)
        let other = PixelRect(x: 512, y: 512, width: 512, height: 512)
        try r.show(other)
        let f = r.metal.footprint
        #expect(r.metal.residentBytes <= cap || f.pages + f.leafImages == f.visiblePages)
        r.metal.pressureCleared()
        #expect(r.metal.limits.residency == 4 << 30)
    }

    @Test func aForgottenViewIsNoLongerVisible() throws {
        guard let r = Self.rig() else { return }
        try r.prime()
        #expect(r.metal.footprint.visiblePages > 0)
        r.metal.forgetView(r.canvas.renderView)
        #expect(r.metal.footprint.visiblePages == 0 && r.metal.footprint.transient == 0)
        // A canvas that goes away forgets itself.
        do {
            let other = try CanvasRenderer()
            let p = r.gpu.plan(Self.doc, region: Self.viewport)
            try other.show(p.plan, region: Self.viewport, source: p.source, compositor: r.metal)
            #expect(r.metal.footprint.visiblePages > 0)
        }
        #expect(r.metal.footprint.visiblePages == 0)
    }

    @Test func observersHearEveryChange() throws {
        guard let r = Self.rig() else { return }
        final class Box: @unchecked Sendable { var seen: [CompositorFootprint] = []; let lock = NSLock() }
        let box = Box()
        r.metal.onFootprintChange = { f in box.lock.lock(); box.seen.append(f); box.lock.unlock() }
        try r.show(Self.viewport)
        let relief = r.metal.relieve(requested: .max, reason: .run)
        r.metal.pressureCleared()
        r.metal.onFootprintChange = nil
        box.lock.lock(); defer { box.lock.unlock() }
        #expect(box.seen.count == 3)
        #expect(box.seen[1] == relief.footprint)
        #expect(box.seen.last == r.metal.lastFootprint)
    }

    @Test func relieveIsFastAndWaitsOutARenderInFlight() throws {
        guard let r = Self.rig() else { return }
        var elapsed: [Double] = []
        for _ in 0..<20 {
            try r.prime()
            elapsed.append(r.metal.relieve(requested: .max, reason: .admission).elapsed)
        }
        let worst = elapsed.max() ?? 0
        #expect(worst <= 0.050, "relieve worst \(worst * 1000) ms")
        // A shrink asked mid-render waits for it, then sheds.
        r.metal.pressureCleared()
        let p = r.gpu.plan(Self.doc, region: Self.doc.bounds)
        let done = DispatchSemaphore(value: 0)
        let metal = r.metal, plan = p
        DispatchQueue.global().async {
            _ = try? metal.render(plan.plan, region: CanvasMemoryTests.doc.bounds, source: plan.source)
            done.signal()
        }
        let relief = r.metal.relieve(requested: .max, reason: .run)
        done.wait()
        #expect(relief.footprint.poolHeaps == 0 || relief.waited == 0)
    }

    @Test func exportBandsDeclareTheirTransient() throws {
        guard let r = Self.rig() else { return }
        try r.prime()
        let band = r.gpu.bandTransient(width: 1024)
        let rows = Int(DocumentCompositor.bandRows(width: 1024, requested: 0))
        #expect(band >= 1024 * rows * 16)
        #expect(r.metal.transientEstimate(region: Self.viewport, outputFormat: .rgba16Float) >= Self.viewport.area * 8)
    }

    /// AB-T-0251's acceptance: with a 16 GB-tier budget (≈ 12.7 GB), floor + transient of a 4096²
    /// 20-layer document after an admission shrink is ≤ 1 GB, and stays there on the next frame.
    @Test func a4096DocumentFitsTheSixteenGigabyteTier() throws {
        guard let metal = try? MetalCompositor(), let canvas = try? CanvasRenderer() else { return }
        let doc = BenchmarkDocuments.realistic20(size: 4096)
        let gpu = DocumentCompositor(rasterizer: DT.rasterizer, backend: .metal, metal: metal)
        metal.memoryBudget = 12_700_000_000
        func show() throws {
            let p = gpu.plan(doc, region: doc.bounds)
            try canvas.show(p.plan, region: doc.bounds, source: p.source, compositor: metal)
        }
        try show(); try show()
        let relief = metal.relieve(requested: .max, reason: .admission)
        let floor = relief.footprint.persistent + canvas.footprint.bytes
        #expect(floor + relief.footprint.transient <= 1_000_000_000, "floor \(floor >> 20) MiB + transient \(relief.footprint.transient >> 20) MiB")
        try show()
        let next = metal.footprint
        #expect(next.persistent + canvas.footprint.bytes + next.transient <= 1_000_000_000)
        #expect(next.visiblePages == relief.footprint.visiblePages)
    }
}
