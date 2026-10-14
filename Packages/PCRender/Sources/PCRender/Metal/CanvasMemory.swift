// New (no photocraft counterpart): what the canvas holds on the GPU and how it gives memory back,
// so a host can declare the canvas to a model engine as one external GPU tenant (AB-A-0169 §2,
// after ForgeCanvasUI's `CanvasPressurePolicy`, AB-R-0315). PCRender stays engine-free: these are
// plain byte counts and shrink levels; the host maps them onto its engine's declaration.
//
// Bytes are Metal's allocation sizes (`allocatedSize`, heap sizes), taken when each texture is
// made: a footprint is a sum over the caches' entries, never a query to the driver. The transient
// parts are estimates from the views' last renders (see `CompositorFootprint.transient`).
//
// "Visible" is what the views' last renders used: `render(…, view:)` (CanvasRenderer.show passes
// its own) records the pages, leaf images, effect maps and masks of that render. A run-level
// shrink keeps all of it, because the next frame would re-upload it (AB-R-0303: a 260–360 ms
// stall per edit, for no lasting relief).

import Foundation
import Metal
import PCFoundation

/// Names a canvas view: its renders define what is visible (`CanvasRenderer.show` passes its own).
public struct RenderView: Hashable, Sendable {
    let id: ObjectIdentifier
    public init(_ object: AnyObject) { id = ObjectIdentifier(object) }
}

/// What `MetalCompositor` holds on the GPU, by cache (bytes).
public struct CompositorFootprint: Sendable, Equatable {
    /// Residency pages of document surfaces (one per leaf, page cell and role).
    public var pages = 0
    /// Derived leaves uploaded whole (vector-mask coverage, effect shapes, inks).
    public var leafImages = 0
    /// Pages bound to build feathered masks (a warm frame doesn't read them).
    public var gatherPages = 0
    /// Effect maps.
    public var effectMaps = 0
    /// Feathered (canvas-wide) masks.
    public var masks = 0
    /// Pattern textures.
    public var patterns = 0
    /// Heaps of the accumulator pool (scratch between renders).
    public var poolHeaps = 0
    /// Of `pages + leafImages`: what the views' last renders bound.
    public var visiblePages = 0
    /// Of `effectMaps + masks`: what the views' last renders used.
    public var visibleEffects = 0
    /// The per-render peak above `persistent` of the next view render: its output texture (when it
    /// allocates one), the accumulators the pool would have to regrow, and map building: one effect
    /// set's intermediates (an edit), or, when effect maps or masks the view used are gone, all of
    /// them rebuilt at once (maps and intermediates). The largest over views (renders are serialized).
    public var transient = 0

    public init() {}

    /// Everything held between renders.
    public var persistent: Int { pages + leafImages + gatherPages + effectMaps + masks + patterns + poolHeaps }
    /// What a run-level shrink may take: everything the next frame won't use.
    public var sheddableOnRun: Int { persistent - visiblePages - visibleEffects }
    /// What a full admission shrink leaves (visible pages; the floor before the display's own bytes).
    public var floor: Int { visiblePages }
    /// What a declaration counts: `persistent + transient`.
    public var declared: Int { persistent + transient }
}

/// What a `CanvasRenderer` holds on the GPU (bytes): never shed by a shrink.
public struct DisplayFootprint: Sendable, Equatable {
    /// The composite texture `setComposite` was given.
    public var composite = 0
    /// Its 2× reduction chain.
    public var levels = 0
    /// The display LUT.
    public var lut = 0

    public init() {}
    public var bytes: Int { composite + levels + lut }

    public static func + (a: DisplayFootprint, b: DisplayFootprint) -> DisplayFootprint {
        var r = a
        r.composite += b.composite; r.levels += b.levels; r.lut += b.lut
        return r
    }
}

/// A rung of the compositor's shrink ladder, cheapest to rebuild first. `relieve(level)` takes every
/// rung up to `level`.
public enum ReliefLevel: Int, CaseIterable, Comparable, Sendable, CustomStringConvertible {
    /// The accumulator pool's heaps (the next render re-creates what it needs).
    case scratch = 1
    /// Pattern textures (re-uploaded from the pattern tiles on use).
    case patterns
    /// Pages, leaf images, gather pages, effect maps and masks no view's last render used; from now
    /// until `pressureCleared`, the caches are capped at what is left.
    case offscreen
    /// Render in smaller cells until `pressureCleared`: the accumulators (the per-render transient)
    /// shrink with the cell's area. Pages stay where they are (no re-upload).
    case lowFootprint
    /// Every effect map and feathered mask, the visible ones too (a cold rebuild: ~813 ms per
    /// effect set on effects4). The next frame rebuilds the visible ones, which the transient then
    /// counts, so this pays only while the canvas doesn't draw; the ladder skips it when it can't.
    case effects

    public static func < (a: ReliefLevel, b: ReliefLevel) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .scratch: "scratch"
        case .patterns: "patterns"
        case .offscreen: "offscreen"
        case .lowFootprint: "lowFootprint"
        case .effects: "effects"
        }
    }
}

/// Why a host asks for memory (an engine's reasons; PCRender imports no engine).
public enum ReliefReason: Sendable {
    /// A model needs room to load; the alternative is evicting or refusing it.
    case admission
    /// A resident model runs over the real-pressure line; nothing is loaded or evicted.
    case run

    /// The deepest rung this reason may take: a run sheds only what the next frame won't use.
    public var deepest: ReliefLevel { self == .run ? .offscreen : .effects }
}

/// The outcome of `MetalCompositor.relieve(requested:reason:)`.
public struct Relief: Sendable {
    /// Bytes asked for.
    public let requested: Int
    /// Bytes the declaration (`persistent + transient`) fell by.
    public var freed: Int { rungs.reduce(0) { $0 + $1.freed } }
    /// Rungs taken, in order, with what each freed.
    public let rungs: [(level: ReliefLevel, freed: Int)]
    /// The footprint afterwards (declare it before answering the engine).
    public let footprint: CompositorFootprint
    /// Seconds spent waiting for the compositor's lock (a render in flight).
    public let waited: Double
    /// Seconds spent shedding under the lock.
    public let elapsed: Double
}

/// The caps the compositor's caches are held to (bytes).
public struct CacheLimits: Sendable, Equatable {
    /// Residency pages, in the logical bytes eviction counts (least recently used evicted first,
    /// never one the current render uses, nor under a budget or relief a visible one).
    public var residency: Int
    /// Effect maps and feathered masks (allocated bytes; visible ones are never evicted under a
    /// budget or relief).
    public var effects: Int
    /// Accumulator heaps kept after a render beyond those the views use (nil: unbounded).
    public var idleHeaps: Int?
    /// Side of the render cells (accumulators are one cell).
    public var renderCell: Int
}

// MARK: - The compositor's side

extension MetalCompositor {
    /// The host's GPU memory budget in bytes (an engine's `memoryBudgetBytes`). It sizes the caps:
    /// residency `residencyShare`, effect maps and masks `effectsShare`, at most `idleHeapLimit`
    /// idle accumulator heaps. nil (the default): `residentBudget`, `cacheBudget`, every heap kept.
    public var memoryBudget: Int? {
        get { locked { budgetBytes } }
        set {
            let fp: CompositorFootprint = locked {
                budgetBytes = newValue.map { max($0, 0) }
                applyCaps()
                return publish()
            }
            notify(fp)
        }
    }

    /// The caps in force now (budget and relief applied).
    public var limits: CacheLimits { locked { limitsLocked } }

    var limitsLocked: CacheLimits {
        var residencyCap = budgetBytes.map { Int(Double($0) * Self.residencyShare) } ?? residency.budget
        var effectsCap = budgetBytes.map { Int(Double($0) * Self.effectsShare) } ?? cacheBudget
        var idle: Int? = budgetBytes == nil ? nil : Self.idleHeapLimit
        if let relief {
            residencyCap = min(residencyCap, relief.residency)
            effectsCap = min(effectsCap, relief.effects)
            idle = min(idle ?? 1, 1)
        }
        return CacheLimits(residency: residencyCap, effects: effectsCap, idleHeaps: idle, renderCell: renderCell)
    }

    /// Side of the cells renders run in now.
    var renderCell: Int {
        guard let relief, relief.level >= .lowFootprint else { return chunkSize }
        return min(chunkSize, max(256, (lowFootprintCell + 255) / 256 * 256))
    }

    /// Whether a budget or relief governs the caches (otherwise they behave as before either existed).
    var governed: Bool { budgetBytes != nil || relief != nil }

    /// The residency cap follows the budget and relief, and never evicts a visible page; ungoverned,
    /// `residency.budget` applies as it always has.
    func applyCaps() {
        residency.cap = governed ? limitsLocked.residency : nil
        residency.protected = governed ? visiblePageKeys() : []
    }

    /// The footprint as of the last render, shrink or change (never waits for a render in flight).
    public var lastFootprint: CompositorFootprint {
        stateLock.lock(); defer { stateLock.unlock() }
        return last
    }

    /// The footprint now (waits for a render in flight).
    public var footprint: CompositorFootprint { locked { footprintLocked() } }

    /// Called after every render, shrink, purge and budget change with the new footprint, on the
    /// thread that made the change and outside the compositor's lock (a host re-declares from it).
    public var onFootprintChange: (@Sendable (CompositorFootprint) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return observer }
        set { stateLock.lock(); observer = newValue; stateLock.unlock() }
    }

    /// Stops counting `view` as visible (a closed canvas). Never waits: applied at the next render
    /// or shrink.
    public func forgetView(_ view: RenderView) {
        stateLock.lock(); forgotten.append(view); stateLock.unlock()
    }

    /// The transient of a render of `region` into a new `outputFormat` texture (an export or
    /// flatten band: raise the declaration by it while the pass runs).
    public func transientEstimate(region: PixelRect, outputFormat: MTLPixelFormat = .rgba32Float) -> Int {
        locked {
            let area = accumulatorArea(region, side: renderCell)
            let need = views.values.map { poolNeed($0, area: area) }.max() ?? oneHeap(area: area)
            return region.area * ResidencyCache.bytesPerPixel(outputFormat) + max(0, need - pool.allocatedBytes)
                + (views.values.map(\.buildBytes).max() ?? 0)
        }
    }

    // MARK: Relief

    /// Sheds every rung up to `level`; returns the bytes the declaration (`persistent + transient`)
    /// fell by. Runs on the calling thread under the compositor's lock, so it waits for a render in
    /// flight and nothing it drops is still in use on the GPU.
    @discardableResult
    public func relieve(_ level: ReliefLevel) -> Int {
        let (freed, fp): (Int, CompositorFootprint) = locked {
            let before = footprintLocked().declared
            for rung in ReliefLevel.allCases where rung <= level { shed(rung) }
            let fp = publish()
            return (before - fp.declared, fp)
        }
        notify(fp)
        return freed
    }

    /// Walks the ladder for `reason` (`ReliefReason.deepest`), one rung at a time, stopping once
    /// `requested` bytes are freed. Never sheds what a view's last render used on a run, and skips
    /// `.effects` when the next frame's rebuild would cost the declaration more than it frees.
    public func relieve(requested: Int, reason: ReliefReason) -> Relief {
        let t0 = Self.clock()
        lock.lock()
        let t1 = Self.clock()
        applyForgotten()
        var rungs: [(level: ReliefLevel, freed: Int)] = []
        var total = 0
        var before = footprintLocked().declared
        if requested > 0 {
            for rung in ReliefLevel.allCases where rung <= reason.deepest {
                // Visible effects come back on the next frame (maps and intermediates, as transient):
                // dropping them only pays when that is less than they hold.
                if rung == .effects && footprintLocked(withoutEffects: true).declared >= before {
                    rungs.append((rung, 0))
                    continue
                }
                shed(rung)
                let after = footprintLocked().declared
                rungs.append((rung, before - after))
                total += before - after
                before = after
                if total >= requested { break }
            }
        }
        let fp = publish()
        let t2 = Self.clock()
        lock.unlock()
        notify(fp)
        return Relief(requested: requested, rungs: rungs, footprint: fp, waited: t1 - t0, elapsed: t2 - t1)
    }

    /// Pressure has cleared: the normal caps and render cells come back. Lazily: nothing is
    /// re-allocated until a render needs it.
    public func pressureCleared() {
        let fp: CompositorFootprint = locked {
            relief = nil
            applyCaps()
            return publish()
        }
        notify(fp)
    }

    /// One rung (under the lock).
    private func shed(_ rung: ReliefLevel) {
        switch rung {
        case .scratch:
            pool.purge()
        case .patterns:
            patternCache.removeAll()
        case .offscreen:
            residency.drop(keeping: visiblePageKeys())
            let (fx, masks) = visibleEffectKeys()
            fxCache = fxCache.filter { fx.contains($0.key) }
            maskCache = maskCache.filter { masks.contains($0.key) }
        case .lowFootprint:
            break
        case .effects:
            fxCache.removeAll(); maskCache.removeAll()
        }
        // The caps hold the caches at what the off-screen rung left (the visible set): panning
        // evicts instead of growing, and a rebuilt visible set still fits after `.effects`.
        var caps = (residency: relief?.residency ?? Int.max, effects: relief?.effects ?? Int.max)
        if rung == .offscreen { caps = (residency.residentBytes, effectBytes()) }
        relief = (max(relief?.level ?? rung, rung), caps.residency, caps.effects)
        applyCaps()
    }

    private func visiblePageKeys() -> Set<ResidencyCache.Key> {
        views.values.reduce(into: Set()) { $0.formUnion($1.pages) }
    }

    private func visibleEffectKeys() -> (Set<CPUCompositor.FxKey>, Set<CPUCompositor.MaskKey>) {
        views.values.reduce(into: (Set(), Set())) { $0.0.formUnion($1.fx); $0.1.formUnion($1.masks) }
    }

    /// Allocated bytes of the effect maps and masks.
    private func effectBytes() -> Int {
        fxCache.values.reduce(0) { $0 + $1.maps.heldBytes } + maskCache.values.reduce(0) { $0 + $1.mask.allocated }
    }

    /// Accumulator texels of the largest cell of `region` cut at `side` (cells round up to 64 px).
    func accumulatorArea(_ region: PixelRect, side: Int) -> Int {
        cellRects(region, side: side).reduce(0) { max($0, (($1.width + 63) / 64 * 64) * (($1.height + 63) / 64 * 64)) }
    }

    /// A heap of eight float accumulators (what a render with no measurement takes at first).
    private func oneHeap(area: Int) -> Int { area * 16 * 8 }

    /// A view's accumulator heaps at `area` per accumulator (its measurement, scaled when the cell
    /// changed since).
    private func poolNeed(_ v: ViewRecord, area: Int) -> Int {
        guard v.accumulatorArea > 0, v.poolBytes > 0 else { return 0 }
        if area == v.accumulatorArea { return v.poolBytes }
        return Int((Double(v.poolBytes) * Double(area) / Double(v.accumulatorArea)).rounded(.up))
    }

    /// The footprint now, or (`withoutEffects`) as it would be with every effect map and mask shed.
    func footprintLocked(withoutEffects: Bool = false) -> CompositorFootprint {
        var f = CompositorFootprint()
        let all = residency.bytes()
        f.pages = all.pages; f.leafImages = all.images; f.gatherPages = all.gather
        f.effectMaps = withoutEffects ? 0 : fxCache.values.reduce(0) { $0 + $1.maps.heldBytes }
        f.masks = withoutEffects ? 0 : maskCache.values.reduce(0) { $0 + $1.mask.allocated }
        f.patterns = patternCache.values.reduce(0) { $0 + $1.texture.allocatedSize }
        f.poolHeaps = pool.allocatedBytes
        let visible = residency.bytes(of: visiblePageKeys())
        f.visiblePages = visible.pages + visible.images
        let (vfx, vmasks) = visibleEffectKeys()
        if !withoutEffects {
            f.visibleEffects = fxCache.reduce(0) { $0 + (vfx.contains($1.key) ? $1.value.maps.heldBytes : 0) }
                + maskCache.reduce(0) { $0 + (vmasks.contains($1.key) ? $1.value.mask.allocated : 0) }
        }
        f.transient = views.values.map { v in
            let need = poolNeed(v, area: accumulatorArea(v.region, side: renderCell))
            // Effect maps and masks the view used that are gone come back on its next frame, all
            // in one build; otherwise allow for one effect set's rebuild (an edit).
            let missing = v.fxRebuild.reduce(0) { $0 + (withoutEffects || fxCache[$1.key] == nil ? $1.value : 0) }
                + v.maskRebuild.reduce(0) { $0 + (withoutEffects || maskCache[$1.key] == nil ? $1.value : 0) }
            return v.outputBytes + max(0, need - pool.allocatedBytes) + max(missing, v.buildBytes)
        }.max() ?? 0
        return f
    }

    /// Stores the footprint for `lastFootprint` (under the lock); `notify` it after unlocking.
    func publish() -> CompositorFootprint {
        let f = footprintLocked()
        stateLock.lock(); last = f; stateLock.unlock()
        return f
    }

    func notify(_ f: CompositorFootprint) {
        stateLock.lock(); let o = observer; stateLock.unlock()
        o?(f)
    }

    func applyForgotten() {
        stateLock.lock(); let gone = forgotten; forgotten.removeAll(); stateLock.unlock()
        for v in gone { views.removeValue(forKey: v) }
        if !gone.isEmpty { applyCaps() }
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        applyForgotten()
        return try body()
    }

    static func clock() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// After a render (under the lock): holds the caches to the limits and publishes the footprint.
    func finishFrame() -> CompositorFootprint {
        if governed {
            applyCaps()
            residency.evict()
            evictCaches()
        }
        if let idle = limitsLocked.idleHeaps {
            pool.trim(keeping: Set(views.values.map(\.frame)), idle: idle)
        }
        return publish()
    }

    /// Eviction under a budget or relief: least recently used first among what neither a view's last
    /// render nor the current one uses (those stay even over the cap).
    func evictGoverned() {
        let cap = limitsLocked.effects
        var bytes = effectBytes()
        if bytes <= cap { return }
        let (vfx, vmasks) = visibleEffectKeys()
        var order: [(tick: UInt64, fx: CPUCompositor.FxKey?, mask: CPUCompositor.MaskKey?)] = []
        for (k, e) in fxCache where !vfx.contains(k) && !frameFx.contains(k) { order.append((e.tick, k, nil)) }
        for (k, e) in maskCache where !vmasks.contains(k) && !frameMasks.contains(k) { order.append((e.tick, nil, k)) }
        for o in order.sorted(by: { $0.tick < $1.tick }) {
            if bytes <= cap { break }
            if let k = o.fx, let e = fxCache.removeValue(forKey: k) { bytes -= e.maps.heldBytes }
            if let k = o.mask, let e = maskCache.removeValue(forKey: k) { bytes -= e.mask.allocated }
        }
    }
}
