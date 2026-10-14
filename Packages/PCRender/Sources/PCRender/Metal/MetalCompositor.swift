// Port of photocraft-gpu (crates/gpu/src/lib.rs `Compositor`, `run_cell`, plan.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Metal compositor: runs the same `RenderPlan` as `CPUCompositor`, cell by cell (page cells
// of `chunkSize`² on a document-aligned grid), each cell's ops encoded as compute dispatches over
// rgba16Float / rgba32Float accumulators drawn from a heap-backed pool. Every op writes a fresh
// accumulator (no in-place hazards); the stack holds shared references, so `.pick` costs nothing.
// Effect maps and feathered masks are built once per leaf version before the cells run and
// cached under a budget, as photocraft-gpu does. What the caches hold, what a view uses and how
// they give memory back (byte accessors, memory budget, shrink ladder): CanvasMemory.swift.

import Foundation
import Metal
import PCDocument
import PCFoundation
import simd

public enum MetalCompositorError: Error, CustomStringConvertible, Equatable {
    case noMetal
    /// The plan needs something only the CPU compositor evaluates (the caller falls back to it).
    case unsupported(String)
    case gpu(String)

    public var description: String {
        switch self {
        case .noMetal: "Metal is unavailable"
        case .unsupported(let s): "GPU compositor: \(s) (composited on the CPU)"
        case .gpu(let s): "GPU compositor: \(s)"
        }
    }
}

/// A composite on the GPU: straight-alpha RGBA of `rect` at the texture's origin.
/// Where the CPU time of the last render went (seconds).
public struct MetalRenderStats: Sendable {
    public var output = 0.0, prepare = 0.0, encode = 0.0, wait = 0.0
}

public struct MetalRenderResult: @unchecked Sendable {
    public let texture: any MTLTexture
    public let rect: PixelRect
    /// GPU time of the render's command buffers (seconds).
    public let gpuTime: Double
    /// Cells (chunks) the region was processed in.
    public let cells: Int
}

public final class MetalCompositor: @unchecked Sendable {
    public let context: MetalContext
    let kernels: PCRKernels
    let pool: TexturePool
    let residency: ResidencyCache
    /// Side of the page cells (a multiple of 256; at most the device's texture limit).
    public var chunkSize: Int { didSet { chunkSize = max(256, (chunkSize + 255) / 256 * 256) } }
    public var precision: AccumulatorPrecision = .automatic
    /// Bytes effect maps and feathered masks may hold on the GPU (without a `memoryBudget`).
    public var cacheBudget: Int = 1536 << 20
    /// Side of the render cells in the low-footprint mode (`ReliefLevel.lowFootprint`).
    public var lowFootprintCell = 512
    /// CPU-side timing of the last `render`.
    public private(set) var lastStats = MetalRenderStats()

    /// Shares of `memoryBudget` the caches may hold, and idle accumulator heaps kept.
    public static let residencyShare = 0.25, effectsShare = 0.10, idleHeapLimit = 2

    let lock = NSLock()
    var fxCache: [CPUCompositor.FxKey: (maps: GPUFxMaps, tick: UInt64)] = [:]
    var maskCache: [CPUCompositor.MaskKey: (mask: GPUMask, tick: UInt64)] = [:]
    var patternCache: [String: (version: UInt64, texture: any MTLTexture)] = [:]
    var tick: UInt64 = 0
    /// Effect maps and masks the current render used.
    var frameFx: Set<CPUCompositor.FxKey> = []
    var frameMasks: Set<CPUCompositor.MaskKey> = []
    /// Bytes of map-building textures allocated so far (build intermediates are differences).
    var mapBytesAllocated = 0

    /// What a view's last render used, and what it took.
    struct ViewRecord {
        var frame: UInt64
        var pages: Set<ResidencyCache.Key>
        var fx: Set<CPUCompositor.FxKey>
        var masks: Set<CPUCompositor.MaskKey>
        var region: PixelRect
        /// The output texture the render allocated (0: it drew into a reused target).
        var outputBytes: Int
        /// Heap bytes its accumulators came from, at `accumulatorArea` per accumulator.
        var poolBytes: Int
        var accumulatorArea: Int
        /// The largest build intermediates among its effect maps and masks.
        var buildBytes: Int
        /// What rebuilding each of its effect maps and masks takes (held + intermediates).
        var fxRebuild: [CPUCompositor.FxKey: Int]
        var maskRebuild: [CPUCompositor.MaskKey: Int]
    }
    var views: [RenderView: ViewRecord] = [:]
    var budgetBytes: Int?
    /// Deepest rung taken since pressure last cleared, and the caps it left.
    var relief: (level: ReliefLevel, residency: Int, effects: Int)?

    /// Guards what may be read without waiting for a render: the last footprint, the observer and
    /// views to forget.
    let stateLock = NSLock()
    var last = CompositorFootprint()
    var observer: (@Sendable (CompositorFootprint) -> Void)?
    var forgotten: [RenderView] = []

    public init(context: MetalContext? = MetalContext.shared, chunkSize: Int = 2048, residentBudget: Int = 4 << 30) throws {
        guard let context else { throw MetalCompositorError.noMetal }
        self.context = context
        kernels = try PCRKernels(context: context)
        pool = TexturePool(device: context.device)
        residency = ResidencyCache(device: context.device, budget: residentBudget)
        self.chunkSize = max(256, (chunkSize + 255) / 256 * 256)
    }

    /// Bytes held by resident leaf pages.
    public var residentBytes: Int { residency.residentBytes }
    /// Tiles uploaded since creation.
    public var tilesUploaded: Int { residency.tilesUploaded }

    /// Drops every cached texture.
    public func purge() {
        let fp: CompositorFootprint = locked {
            fxCache.removeAll(); maskCache.removeAll(); patternCache.removeAll()
            residency.purge(); pool.purge()
            return publish()
        }
        notify(fp)
    }

    /// Why `plan` can't run on the GPU, or nil when it can.
    public func unsupportedReason(_ plan: RenderPlan) -> String? {
        for op in plan.ops {
            if case .adjust(let a) = op, GPUAdjustment.needsCPU(a, plan.context) {
                return "\(a.label) in a CMYK tone space with a managed CMYK converter"
            }
        }
        return nil
    }

    /// Composites `plan` over `region` on the GPU into a new region-sized texture.
    /// `into`: a texture of at least the region's size to composite into (reused across frames:
    /// a fresh 4096² float texture costs its page mapping on every render); nil allocates one.
    /// `view`: the canvas view this render draws (what it uses counts as visible until the view's
    /// next render; see CanvasMemory.swift).
    public func render(_ plan: RenderPlan, region: PixelRect, source: any RenderSource,
                       outputFormat: MTLPixelFormat = .rgba32Float, outputStorage: MTLStorageMode = .private,
                       into target: (any MTLTexture)? = nil, view: RenderView? = nil) throws -> MetalRenderResult {
        func clock() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
        var stats = MetalRenderStats()
        var t = clock()
        func lap(_ k: WritableKeyPath<MetalRenderStats, Double>) { let n = clock(); stats[keyPath: k] += n - t; t = n }
        do { try plan.validate() } catch { throw MetalCompositorError.gpu(error.description) }
        if let why = unsupportedReason(plan) { throw MetalCompositorError.unsupported(why) }
        let reused = target.flatMap({ $0.width >= region.width && $0.height >= region.height ? $0 : nil })
        guard !region.isEmpty,
              let out = reused
                ?? context.makeTexture(width: region.width, height: region.height, pixelFormat: outputFormat,
                                       usage: [.shaderRead, .shaderWrite], storage: outputStorage) else {
            throw MetalCompositorError.gpu("output texture \(region)")
        }
        lock.lock()
        applyForgotten()
        lap(\.output)
        residency.beginFrame()
        let frame = residency.currentFrame
        pool.frame = frame
        pool.frameIsView = view != nil
        frameFx.removeAll(); frameMasks.removeAll()
        let result: MetalRenderResult
        do {
            result = try renderLocked(plan, region: region, source: source, out: out, lap: lap)
            lastStats = stats
        } catch {
            let fp = finishFrame()
            lock.unlock()
            notify(fp)
            throw error
        }
        if let view {
            var fxRebuild: [CPUCompositor.FxKey: Int] = [:], maskRebuild: [CPUCompositor.MaskKey: Int] = [:]
            for k in frameFx { if let m = fxCache[k]?.maps { fxRebuild[k] = m.heldBytes + m.buildBytes } }
            for k in frameMasks { if let m = maskCache[k]?.mask { maskRebuild[k] = m.allocated + m.buildBytes } }
            let build = max(frameFx.compactMap { fxCache[$0]?.maps.buildBytes }.max() ?? 0,
                            frameMasks.compactMap { maskCache[$0]?.mask.buildBytes }.max() ?? 0)
            views[view] = ViewRecord(frame: frame, pages: residency.keys(usedIn: frame), fx: frameFx, masks: frameMasks, region: region,
                                     outputBytes: reused == nil ? out.allocatedSize : 0,
                                     poolBytes: pool.bytes(touchedIn: frame), accumulatorArea: accumulatorArea(region, side: renderCell),
                                     buildBytes: build, fxRebuild: fxRebuild, maskRebuild: maskRebuild)
        }
        let fp = finishFrame()
        lock.unlock()
        notify(fp)
        return result
    }

    private func renderLocked(_ plan: RenderPlan, region: PixelRect, source: any RenderSource, out: any MTLTexture,
                              lap: (WritableKeyPath<MetalRenderStats, Double>) -> Void) throws -> MetalRenderResult {
        let accFormat = precision.format(for: plan)
        var gpuTime = 0.0
        // Effect maps and feathered masks first (their own command buffer; the cells read them).
        // Command buffers are committed back to back and waited for once: the queue runs them in
        // order, and textures recycled between cells are hazard-tracked.
        let prepared = try prepare(plan, source: source)
        lap(\.prepare)
        var committed: [any MTLCommandBuffer] = []
        if let cb = prepared.commandBuffer {
            cb.commit()
            committed.append(cb)
        }
        let cells = cellRects(region, side: renderCell)
        for cell in cells {
            guard let cb = context.queue.makeCommandBuffer() else { throw MetalCompositorError.gpu("command buffer") }
            cb.label = "PCRender cell \(cell)"
            guard let enc = cb.makeComputeCommandEncoder() else { throw MetalCompositorError.gpu("compute encoder") }
            var run = CellRun(compositor: self, plan: plan, prepared: prepared, source: source, cell: cell, enc: enc, format: accFormat)
            let root = try run.execute()
            var o = run.baseOp()
            o.aux = SIMD2(cell.x0 - region.x0, cell.y0 - region.y0)
            kernels.dispatch(enc, try kernels.pipeline("pcr_copy_out"), op: o, grid: (cell.width, cell.height), textures: [Slot.a: root.texture, Slot.out: out])
            enc.endEncoding()
            cb.commit()
            committed.append(cb)
            run.releaseAll()
        }
        lap(\.encode)
        var start = Double.infinity, end = 0.0
        for cb in committed {
            cb.waitUntilCompleted()
            if let e = cb.error { throw MetalCompositorError.gpu(e.localizedDescription) }
            start = min(start, cb.gpuStartTime); end = max(end, cb.gpuEndTime)
        }
        gpuTime = committed.isEmpty ? 0 : max(end - start, 0)
        lap(\.wait)
        return MetalRenderResult(texture: out, rect: region, gpuTime: gpuTime, cells: cells.count)
    }

    /// Renders and reads the composite back (tests, export).
    public func renderBuffer(_ plan: RenderPlan, region: PixelRect, source: any RenderSource) throws -> RGBABuffer {
        let r = try render(plan, region: region, source: source, outputFormat: .rgba32Float, outputStorage: .shared)
        let img = context.readImage(r.texture, rect: region, channels: 4)
        return RGBABuffer(img)
    }

    /// The region cut along the cell grid of `side` (the page cells by default).
    func cellRects(_ region: PixelRect, side: Int? = nil) -> [PixelRect] {
        let s = Int32(side ?? chunkSize)
        func floorDiv(_ a: Int32) -> Int32 { a >= 0 ? a / s : -((-a + s - 1) / s) }
        var out: [PixelRect] = []
        var y = floorDiv(region.y0) * s
        while y < region.y1 {
            var x = floorDiv(region.x0) * s
            while x < region.x1 {
                out.append(PixelRect(x0: x, y0: y, x1: x + s, y1: y + s).intersect(region))
                x += s
            }
            y += s
        }
        return out.filter { !$0.isEmpty }
    }

    /// The page cell containing `r`.
    func cellOf(_ r: PixelRect) -> PixelRect {
        let s = Int32(chunkSize)
        func floorDiv(_ a: Int32) -> Int32 { a >= 0 ? a / s : -((-a + s - 1) / s) }
        let x = floorDiv(r.x0) * s, y = floorDiv(r.y0) * s
        return PixelRect(x0: x, y0: y, x1: x + s, y1: y + s)
    }

    func nextTick() -> UInt64 { tick += 1; return tick }

    // MARK: Preparation

    struct Prepared {
        var maps: [Int: GPUFxMaps] = [:]
        var masks: [MaskSpec: GPUMask] = [:]
        var adjustments: [Int: GPUAdjustment] = [:]
        var commandBuffer: (any MTLCommandBuffer)?
    }

    private func prepare(_ plan: RenderPlan, source: any RenderSource) throws -> Prepared {
        var p = Prepared()
        let ctx = plan.context
        var enc: (any MTLComputeCommandEncoder)?
        func encoder() throws -> any MTLComputeCommandEncoder {
            if let enc { return enc }
            guard let cb = context.queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { throw MetalCompositorError.gpu("prepare encoder") }
            cb.label = "PCRender prepare"
            p.commandBuffer = cb
            enc = e
            return e
        }
        func needMask(_ m: MaskSpec?) throws {
            guard let m, m.hasFeather, p.masks[m] == nil else { return }
            p.masks[m] = try gpuMask(m, ctx: ctx, source: source, encoder: encoder)
        }
        for (i, op) in plan.ops.enumerated() {
            switch op {
            case .adjust(let a): p.adjustments[i] = GPUAdjustment(a, ctx, kernels: kernels)
            case .effect(let spec, _):
                p.maps[i] = try gpuMaps(spec, ctx: ctx, source: source, encoder: encoder)
                try needMask(spec.vectorStrokeMask)
            case .drawTiles(let d): try needMask(d.mask)
            case .fill(let f): try needMask(f.mask)
            case .pushMaskShape(let m): try needMask(m)
            case .mask(let m): try needMask(m)
            case .adjustMix(let a): try needMask(a.mask)
            case .popGroup(.isolated(let m)): try needMask(m)
            case .popGroup(.passThrough(_, let m)): try needMask(m)
            default: break
            }
        }
        enc?.endEncoding()
        evictCaches()
        return p
    }

    func evictCaches() {
        if governed { return evictGoverned() }
        var bytes = fxCache.values.reduce(0) { $0 + $1.maps.bytes } + maskCache.values.reduce(0) { $0 + $1.mask.bytes }
        while bytes > cacheBudget && fxCache.count + maskCache.count > 1 {
            let oldFx = fxCache.min { $0.value.tick < $1.value.tick }
            let oldMask = maskCache.min { $0.value.tick < $1.value.tick }
            if let f = oldFx, oldMask.map({ f.value.tick < $0.value.tick }) ?? true {
                bytes -= f.value.maps.bytes; fxCache.removeValue(forKey: f.key)
            } else if let m = oldMask {
                bytes -= m.value.mask.bytes; maskCache.removeValue(forKey: m.key)
            } else { break }
        }
    }

    /// A premultiplied RGBA32F texture of a pattern (cached by id and version).
    func patternTexture(_ tile: PatternTile) -> (any MTLTexture)? {
        let key = tile.id + "\u{0}" + tile.name
        if let hit = patternCache[key], hit.version == tile.version { return hit.texture }
        guard let t = context.makeTexture(width: tile.width, height: tile.height, pixelFormat: .rgba32Float, usage: [.shaderRead]) else { return nil }
        tile.premultiplied.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, tile.width, tile.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: tile.width * 16)
        }
        patternCache[key] = (tile.version, t)
        return t
    }

    /// A shared r32Float texture holding `values` (row-major over `w × h`).
    func valuesTexture(_ values: [Float], _ w: Int, _ h: Int) -> (any MTLTexture)? {
        guard let t = context.makeTexture(width: w, height: h, pixelFormat: .r32Float, usage: [.shaderRead, .shaderWrite]) else { return nil }
        mapBytesAllocated += t.allocatedSize
        if w > 0 && h > 0 {
            values.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        }
        return t
    }

    /// A private r32Float working texture.
    func mapTexture(_ w: Int, _ h: Int) -> (any MTLTexture)? {
        let t = context.makeTexture(width: w, height: h, pixelFormat: .r32Float, usage: [.shaderRead, .shaderWrite], storage: .private)
        if let t { mapBytesAllocated += t.allocatedSize }
        return t
    }
}

/// A shared reference to an accumulator.
final class StackTex {
    let texture: any MTLTexture
    var refs = 1
    init(_ t: any MTLTexture) { texture = t }
}

/// One cell's execution of the plan: the stack machine over pooled accumulators.
struct CellRun {
    let compositor: MetalCompositor
    let plan: RenderPlan
    let prepared: MetalCompositor.Prepared
    let source: any RenderSource
    let cell: PixelRect
    let enc: any MTLComputeCommandEncoder
    let format: MTLPixelFormat
    var stack: [StackTex] = []
    var floors: [StackTex] = []
    /// Every texture taken from the pool (returned after the cell's command buffer completes).
    var taken: [any MTLTexture] = []
    var k: PCRKernels { compositor.kernels }
    /// Accumulator size (the cell rounded up to 64 px, so edge cells share pool textures).
    let tw: Int, th: Int

    init(compositor: MetalCompositor, plan: RenderPlan, prepared: MetalCompositor.Prepared, source: any RenderSource, cell: PixelRect,
         enc: any MTLComputeCommandEncoder, format: MTLPixelFormat) {
        self.compositor = compositor; self.plan = plan; self.prepared = prepared; self.source = source
        self.cell = cell; self.enc = enc; self.format = format
        tw = (cell.width + 63) / 64 * 64
        th = (cell.height + 63) / 64 * 64
    }

    mutating func releaseAll() {
        for t in taken { compositor.pool.give(t) }
        taken.removeAll()
    }

    /// A fresh accumulator (or r32Float map) for this cell.
    mutating func fresh(_ f: MTLPixelFormat? = nil) -> any MTLTexture {
        let t = compositor.pool.take(tw, th, f ?? format)
        taken.append(t)
        return t
    }

    /// Returns a texture to the pool for the rest of the cell (dispatches in one serial encoder run
    /// in order, so a later write can't overtake an earlier read).
    mutating func recycle(_ t: any MTLTexture) {
        if let i = taken.firstIndex(where: { $0 === t }) {
            taken.remove(at: i)
            compositor.pool.give(t)
        }
    }

    /// Drops one reference to each of `xs`, recycling those no longer referenced.
    mutating func release(_ xs: StackTex...) {
        for x in xs {
            x.refs -= 1
            if x.refs == 0 { recycle(x.texture) }
        }
    }

    /// The base uniform record of a full-cell dispatch.
    func baseOp(_ clip: PixelRect? = nil) -> PCROp {
        var op = PCROp()
        let r = (clip ?? cell).intersect(cell)
        op.origin = SIMD2(cell.x0, cell.y0)
        op.offset = SIMD2(r.x0 - cell.x0, r.y0 - cell.y0)
        op.size = SIMD2(Int32(r.width), Int32(r.height))
        if plan.context.space.lab { op.flags |= PCROp.flagLab }
        if plan.context.space.hdr { op.flags |= PCROp.flagHDR }
        if plan.context.native == .lab { op.flags |= PCROp.flagNativeLab }
        if plan.context.native == .cmykBlack { op.flags |= PCROp.flagKPlane }
        if plan.context.space.ps8 { op.flags |= PCROp.flagPS8 }
        return op
    }

    func grid(_ op: PCROp) -> (Int, Int) { (Int(op.size.x), Int(op.size.y)) }

    func leaf(_ id: LeafID) throws -> RenderLeaf {
        guard let l = source.leaf(id) else { throw MetalCompositorError.gpu(PlanError.missingLeaf(id).description) }
        return l
    }

    /// A leaf bound for this cell.
    func bindLeaf(_ id: LeafID, values: Bool) throws -> LeafBinding {
        compositor.residency.bind(id, try leaf(id), values: values, cell: compositor.cellOf(cell))
    }

    /// Mask fields of `op` and textures for `spec` (nil: no mask).
    func bindMask(_ spec: MaskSpec?, _ op: inout PCROp, _ tex: inout [Int: any MTLTexture]) throws {
        guard let spec else { return }
        if spec.hasFeather, let m = prepared.masks[spec] {
            op.flags |= PCROp.flagMask | PCROp.flagCombined
            op.maskOrigin = SIMD2(m.area.x0, m.area.y0)
            op.maskSize = SIMD2(Int32(m.area.width), Int32(m.area.height))
            op.maskDefault = m.outside
            if let t = m.texture { tex[Slot.mask] = t } else { op.maskSize = .zero }
            return
        }
        if let p = spec.pixel {
            let b = try bindLeaf(p, values: true)
            op.flags |= PCROp.flagMask
            if spec.density < 1 { op.flags |= PCROp.flagDensity }
            op.density = spec.density
            op.maskDefault = b.outside.x
            op.maskOrigin = b.origin
            op.maskSize = b.texture == nil ? .zero : b.size
            if let t = b.texture { tex[Slot.mask] = t }
        }
        if let v = spec.vector {
            let b = try bindLeaf(v, values: true)
            op.flags |= PCROp.flagVMask
            op.vmaskOutside = b.outside.x
            op.vmaskOrigin = b.origin
            op.vmaskSize = b.texture == nil ? .zero : b.size
            if let t = b.texture { tex[Slot.vmask] = t }
        }
        if spec.pixel == nil && spec.vector == nil {
            // A mask with no parts is all ones.
            op.flags |= PCROp.flagMask | PCROp.flagCombined
            op.maskDefault = 1
            op.maskSize = .zero
        }
    }

    mutating func push(_ t: any MTLTexture) { stack.append(StackTex(t)) }

    mutating func pop() -> StackTex { stack.removeLast() }

    mutating func run(_ name: String, _ op: PCROp, _ textures: [Int: any MTLTexture], buffers: [Int: any MTLBuffer] = [:]) throws -> any MTLTexture {
        let out = fresh()
        var t = textures
        t[Slot.out] = out
        compositor.kernels.dispatch(enc, try k.pipeline(name), op: op, grid: grid(op), textures: t, buffers: buffers)
        return out
    }

    mutating func execute() throws -> StackTex {
        for (i, op) in plan.ops.enumerated() { try exec(op, i) }
        return stack[0]
    }

    mutating func exec(_ op: DrawOp, _ index: Int) throws {
        switch op {
        case .pushGroup(.isolated), .pushTransparent:
            push(try run("pcr_clear", baseOp(), [:]))
        case .pushGroup(.passThrough), .pick(0):
            let top = stack[stack.count - 1]
            top.refs += 1
            stack.append(top)
        case .pick(let n):
            let s = stack[stack.count - 1 - n]
            s.refs += 1
            stack.append(s)
        case .popGroup(.isolated(let m)):
            guard let m else { return }
            let a = pop()
            var o = baseOp(); var tex: [Int: any MTLTexture] = [Slot.a: a.texture]
            try bindMask(m, &o, &tex)
            push(try run("pcr_apply_mask", o, tex))
            release(a)
        case let .popGroup(.passThrough(opacity, m)):
            let after = pop(), before = pop()
            if opacity >= 1 && m == nil { stack.append(after); release(before); return }
            var o = baseOp(); o.opacity = opacity
            var tex: [Int: any MTLTexture] = [Slot.a: before.texture, Slot.b: after.texture]
            try bindMask(m, &o, &tex)
            push(try run("pcr_pass_mix", o, tex))
            release(before, after)
        case .drop:
            release(pop())
        case .swap:
            stack.swapAt(stack.count - 1, stack.count - 2)
        case .remove(let n):
            release(stack.remove(at: stack.count - 1 - n))
        case .drawTiles(let d):
            var o = baseOp(); var tex: [Int: any MTLTexture] = [:]
            if let id = d.leaf {
                let b = try bindLeaf(id, values: false)
                o.leafOutside = b.outside
                if let t = b.texture { o.flags |= PCROp.flagLeaf; o.leafOrigin = b.origin; o.leafSize = b.size; tex[Slot.leaf] = t }
            }
            try bindMask(d.mask, &o, &tex)
            push(try run("pcr_draw_leaf", o, tex))
        case .fill(let f):
            push(try fill(f))
        case .pushMaskShape(let m):
            var o = baseOp(); var tex: [Int: any MTLTexture] = [:]
            if let m { try bindMask(m, &o, &tex) }
            push(try run("pcr_mask_shape", o, tex))
        case .mask(let m):
            let a = pop()
            var o = baseOp(); var tex: [Int: any MTLTexture] = [Slot.a: a.texture]
            try bindMask(m, &o, &tex)
            push(try run("pcr_apply_mask", o, tex))
            release(a)
        case .composite(let lb):
            let src = pop(), b = pop()
            var o = baseOp(); o.mode = lb.mode.rawValue; o.opacity = lb.opacity; o.fill = lb.fill; o.gamma = lb.textGamma
            push(try run("pcr_composite", o, [Slot.a: b.texture, Slot.b: src.texture]))
            release(src, b)
        case .beginClipBase:
            break
        case .clipped(let lb):
            let src = pop(), base = pop()
            var o = baseOp(); o.mode = lb.mode.rawValue; o.opacity = lb.opacity; o.fill = lb.fill; o.gamma = lb.textGamma
            push(try run("pcr_atop", o, [Slot.a: base.texture, Slot.b: src.texture]))
            release(src, base)
        case .adjust:
            guard let adj = prepared.adjustments[index] else { return }
            let a = pop()
            var o = baseOp()
            adj.fill(&o)
            let out = fresh()
            compositor.kernels.dispatch(enc, try k.adjustPipeline(adj.kind), op: o, grid: grid(o), textures: [Slot.a: a.texture, Slot.out: out],
                                        buffers: [1: adj.buffer])
            push(out)
            release(a)
        case .adjustMix(let a):
            let adjusted = pop(), b = pop()
            var o = baseOp(); o.mode = a.mode.rawValue; o.opacity = a.opacity
            var tex: [Int: any MTLTexture] = [Slot.a: b.texture, Slot.b: adjusted.texture]
            try bindMask(a.mask, &o, &tex)
            push(try run("pcr_adjust_mix", o, tex))
            release(adjusted, b)
        case .quantize(let q):
            let a = pop()
            var o = baseOp(); o.p0.x = q
            push(try run("pcr_quantize", o, [Slot.a: a.texture]))
            release(a)
        case .finishLayer(let f):
            let after = pop()
            let own = f.hasOwn ? pop() : nil
            let before = pop()
            var o = baseOp()
            var tex: [Int: any MTLTexture] = [Slot.a: before.texture, Slot.b: after.texture]
            if let own { tex[Slot.c] = own.texture; o.flags |= PCROp.flagOwn }
            if let w = f.channels { o.flags |= PCROp.flagChannels; o.p0 = SIMD4(w, 1) }
            var ranges = [SIMD4<Float>](repeating: SIMD4(0, 0, 255, 255), count: 10)
            if let bi = f.blendIf {
                o.flags |= PCROp.flagBlendIf
                if plan.context.mode == .rgb { o.flags |= PCROp.flagRGBMode }
                for e in 0..<5 {
                    let pair = bi.get(e)
                    let (t, u) = (pair.this, pair.underlying)
                    ranges[e * 2] = SIMD4(Float(t.black.x), Float(t.black.y), Float(t.white.x), Float(t.white.y))
                    ranges[e * 2 + 1] = SIMD4(Float(u.black.x), Float(u.black.y), Float(u.white.x), Float(u.white.y))
                }
            }
            push(try run("pcr_finish", o, tex, buffers: [1: k.buffer(ranges)!]))
            release(before, after)
            if let own { release(own) }
        case let .effect(spec, atop):
            let content = pop(), backdrop = pop()
            guard let maps = prepared.maps[index] else { stack.append(backdrop); release(content); return }
            push(try effect(spec, atop: atop, maps: maps, backdrop: backdrop.texture, content: content.texture))
            release(content, backdrop)
        case .saveFloor:
            let top = stack[stack.count - 1]
            top.refs += 1
            floors.append(top)
        case .pushFloor:
            let f = floors[floors.count - 1]
            f.refs += 1
            stack.append(f)
        case .dropFloor:
            release(floors.removeLast())
        case .knockoutBegin(let clipAlpha):
            let backdrop = pop(), shape = pop(), target = pop()
            var o = baseOp()
            if clipAlpha { o.flags |= PCROp.flagClipAlpha }
            let knocked = try run("pcr_knockout_begin", o, [Slot.a: target.texture, Slot.b: shape.texture, Slot.c: backdrop.texture])
            release(target)
            stack.append(backdrop); stack.append(shape)
            let kt = StackTex(knocked); kt.refs = 2
            stack.append(kt); stack.append(kt)
        case .knockoutEnd(let opacity):
            let after = pop(), knocked = pop(), shape = pop(), before = pop()
            if opacity >= 1 { stack.append(after); release(knocked, shape, before); return }
            var o = baseOp(); o.opacity = opacity
            push(try run("pcr_knockout_end", o, [Slot.a: before.texture, Slot.b: shape.texture, Slot.c: knocked.texture, Slot.d: after.texture]))
            release(after, knocked, shape, before)
        case .mixBy(let kk):
            let shape = pop(), after = pop(), before = pop()
            var o = baseOp(); o.p0.x = kk
            push(try run("pcr_mix_by", o, [Slot.a: before.texture, Slot.b: after.texture, Slot.c: shape.texture]))
            release(shape, after, before)
        case .addDifference:
            let without = pop(), with = pop(), a = pop()
            push(try run("pcr_add_difference", baseOp(), [Slot.a: a.texture, Slot.b: with.texture, Slot.c: without.texture]))
            release(without, with, a)
        case .restrictTo(let r):
            let after = pop(), before = pop()
            var o = baseOp(); o.p0 = SIMD4(Float(r.x0), Float(r.y0), Float(r.x1), Float(r.y1))
            push(try run("pcr_restrict", o, [Slot.a: before.texture, Slot.b: after.texture]))
            release(before, after)
        }
    }

    /// Fill-layer content (`compose::render_fill`).
    mutating func fill(_ f: FillOp) throws -> any MTLTexture {
        var o = baseOp()
        var tex: [Int: any MTLTexture] = [:]
        try bindMask(f.mask, &o, &tex)
        switch f.fill {
        case .solid(let c):
            var v = simd_clamp(SIMD4(c.rgb, c.alpha), .zero, SIMD4(repeating: 1))
            if let q = plan.context.storageQuantum { v = ((v * q + 0.5).rounded(.down)) / q }
            o.leafOutside = v
            return try run("pcr_draw_leaf", o, tex)
        case .gradient(let g):
            let ramp = GradientMath.FillRamp(g)
            let (angle, scale, offset) = GradientMath.layout(g.style, angle: g.angle, scale: g.scale, offset: g.offset, frame: f.frame)
            o.p0 = SIMD4(angle, scale, g.reverse ? 1 : 0, g.style.index)
            o.p1 = SIMD4(Float(f.frame.x0), Float(f.frame.y0), Float(f.frame.width), Float(f.frame.height))
            let q = plan.context.quantum
            o.p2 = SIMD4(offset.x, offset.y, q ?? 0, plan.context.storageQuantum ?? 0)
            if g.dither { o.flags |= PCROp.flagDither; if q != nil { o.flags |= PCROp.flagQuant } }
            let packed = ramp.packed
            var stops: [SIMD4<Float>] = packed.color
            for (i, a) in packed.alpha.enumerated() { stops.append(SIMD4(a.y, i < packed.mids.count ? packed.mids[i] : 0.5, 0, 0)) }
            stops.append(contentsOf: ramp.opacity.map { SIMD4($0.0, $0.1, 0, 0) })
            o.aux = SIMD2(Int32(packed.color.count), Int32(ramp.opacity.count))
            return try run("pcr_fill_gradient", o, tex, buffers: [1: k.buffer(stops)!])
        case .pattern(let pf):
            guard let tile = source.pattern(id: pf.id, name: pf.name), tile.isPaintable, let pt = compositor.patternTexture(tile) else {
                o.leafOutside = .zero
                o.flags &= ~(PCROp.flagMask | PCROp.flagVMask)
                return try run("pcr_draw_leaf", o, [:])
            }
            let pl = PatternPlacement(frame: f.frame, link: pf.link, phase: pf.phase, scale: pf.scale, angle: pf.angle)
            o.p0 = SIMD4(Float(pl.origin.x), Float(pl.origin.y), Float(pl.cs.x), Float(pl.cs.y))
            o.p1 = SIMD4(Float(pl.invScale), Float(tile.width), Float(tile.height), plan.context.storageQuantum ?? 0)
            tex[Slot.leaf] = pt
            return try run("pcr_fill_pattern", o, tex)
        }
    }
}
