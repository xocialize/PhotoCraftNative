// Port of photocraft-paint (crates/paint/src/render.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Metal stroke renderer: the same stroke as `StrokeRenderer` (same dab generator, same
// build-up-to-opacity accumulation, same composite), with dab rasterisation + accumulation and the
// stroke composite running as compute kernels (Shaders/PCPaint.metal). Coverage lives in pooled
// 64×64 r32Float tiles in shared MTLBuffers (only touched tiles exist — stroke-local tile storage,
// an idea taken from Compositor v1.5, MIT © 2026 Wonder Assembly LLC); per batch the CPU builds the
// GPU dab records and per-tile dab bins (stroke order), the kernel walks each bin per pixel.
// The composite stages the pre-stroke 256² surface tiles, composites in place, and copies the
// clipped rows back into the target; formats/modes the kernel does not cover (non-Normal blend
// modes in CMYK/Lab, which need the managed CMYK transform) composite on the CPU from the GPU
// coverage. Damage is reported per batch.

import Foundation
import Metal
import PCFoundation

// MARK: GPU records (layouts mirror PCPaint.metal)

struct PcpDab {
    var cx: Float = 0, cy: Float = 0
    var r: Float = 0, ro: Float = 0, rm: Float = 0, reach2: Float = 0, smallReach2: Float = 0
    var sn: Float = 0, cs: Float = 1, fx: Float = 1, fy: Float = 1
    var pax: Float = 0, pay: Float = 0, pk: Float = 0
    var alpha: Float = 0, ceilv: Float = 1, texDepth: Float = 1
    var invScale: Float = 1, tw: Float = 1, th: Float = 1
    var level: UInt32 = 0, flags: UInt32 = 0
    var x0: Int32 = 0, y0: Int32 = 0, x1: Int32 = 0, y1: Int32 = 0
    var col: (Float, Float, Float, Float) = (0, 0, 0, 0)
}

struct PcpRaster {
    var hardness: Float = 1
    var aliased: UInt32 = 0, square: UInt32 = 0, noise: UInt32 = 0, texTip: UInt32 = 0
    var wantDepth: UInt32 = 0, wantCol: UInt32 = 0, sampled: UInt32 = 0
    var nc: UInt32 = 0, texMode: UInt32 = 0, patW: UInt32 = 1, patH: UInt32 = 1
    var texScale: Float = 1
    var jobCount: UInt32 = 0
    var pad0: UInt32 = 0, pad1: UInt32 = 0
}

struct PcpJob {
    var slot: UInt32
    var tx: Int32, ty: Int32
    var binStart: UInt32, binCount: UInt32
    var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
}

struct PcpComp {
    var sample: UInt32 = 0, channels: UInt32 = 0, alphaIdx: UInt32 = .max, nc: UInt32 = 0
    var mode: UInt32 = 1, flags: UInt32 = 0
    var opacity: Float = 1
    var seedLo: UInt32 = 0, seedHi: UInt32 = 0
    var dualMode: UInt32 = 0, texMode: UInt32 = 0
    var texDepth: Float = 1, texScale: Float = 1
    var patW: Int32 = 1, patH: Int32 = 1
    var jobCount: UInt32 = 0
    var src: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
    var passes: UInt32 = 1
    var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
}

struct PcpCJob {
    /// Coverage and dual slots of up to four symmetry passes (−1: the pass has no tile here).
    var covSlots: (Int32, Int32, Int32, Int32)
    var dualSlots: (Int32, Int32, Int32, Int32)
    var stage: UInt32
    var tx: Int32, ty: Int32
    var stx: Int32, sty: Int32
    var x0: Int32, y0: Int32, x1: Int32, y1: Int32
    var pad: UInt32 = 0
}

extension MaskMode {
    /// Index matching PCPaint.metal's mask-mode switch.
    var gpuIndex: UInt32 { UInt32(MaskMode.allCases.firstIndex(of: self)!) }
}

public enum MetalPaintError: Error, CustomStringConvertible {
    case noMetal
    case allocation(String)
    case tooManyChannels(Int)
    public var description: String {
        switch self {
        case .noMetal: "no Metal device"
        case .allocation(let s): "Metal allocation failed: \(s)"
        case .tooManyChannels(let n): "\(n)-channel pixels exceed the composite kernel's 8"
        }
    }
}

// MARK: Tile pool

/// A tile of one symmetry pass.
struct PassKey: Hashable, Sendable {
    var pass: Int
    var key: CovKey
}

/// 64×64 float tiles pooled in shared buffers: coverage, optional wet-edge depth, optional
/// per-dab colour (`nc` floats per pixel). Slots past `count` are scratch (live tail previews).
final class GPUTilePool {
    let device: any MTLDevice
    let nc: Int
    let wantDepth: Bool
    private(set) var slots: [PassKey: UInt32] = [:]
    private(set) var count = 0
    private(set) var scratchCount = 0
    private(set) var capacity = 0
    private(set) var cov: any MTLBuffer
    private(set) var depth: (any MTLBuffer)?
    private(set) var col: (any MTLBuffer)?
    static let px = Int(covTile * covTile)

    init(device: any MTLDevice, nc: Int, wantDepth: Bool, capacity: Int = 64) throws {
        self.device = device
        self.nc = nc
        self.wantDepth = wantDepth
        guard let b = device.makeBuffer(length: 4, options: .storageModeShared) else { throw MetalPaintError.allocation("tile pool") }
        cov = b
        try grow(to: capacity)
    }

    /// Every coverage key any pass holds, sorted.
    var sortedKeys: [CovKey] { Set(slots.keys.map(\.key)).sorted() }

    func slot(_ pass: Int, _ key: CovKey) -> UInt32? { slots[PassKey(pass: pass, key: key)] }

    /// Slots needed for `keys` of `pass` that don't exist yet.
    func missing(_ pass: Int, _ keys: some Sequence<CovKey>) -> Int {
        keys.reduce(0) { $0 + (slots[PassKey(pass: pass, key: $1)] == nil ? 1 : 0) }
    }

    /// Grow to hold at least `n` slots. The caller guarantees no GPU work is pending on the pool.
    func grow(to n: Int) throws {
        if n <= capacity { return }
        let newCap = max(n, capacity * 2, 16)
        func remake(_ old: (any MTLBuffer)?, _ perPixel: Int) throws -> any MTLBuffer {
            let len = newCap * GPUTilePool.px * perPixel * 4
            guard let b = device.makeBuffer(length: max(len, 4), options: .storageModeShared) else {
                throw MetalPaintError.allocation("\(len) bytes")
            }
            let used = (count + scratchCount) * GPUTilePool.px * perPixel * 4
            if let old, used > 0 { memcpy(b.contents(), old.contents(), used) }
            memset(b.contents() + used, 0, len - used)
            return b
        }
        cov = try remake(capacity > 0 ? cov : nil, 1)
        if wantDepth { depth = try remake(depth, 1) }
        if nc > 0 { col = try remake(col, nc) }
        capacity = newCap
    }

    /// The slot holding `key` of `pass`, allocating (zeroed) when new. Scratch must be released first.
    func allocate(_ pass: Int, _ key: CovKey) -> UInt32 {
        let pk = PassKey(pass: pass, key: key)
        if let s = slots[pk] { return s }
        precondition(scratchCount == 0 && count < capacity, "tile pool: grow before allocating")
        let s = UInt32(count)
        slots[pk] = s
        count += 1
        // Released scratch slots (live tail previews) leave data behind: start clean. No pending
        // GPU work can reference this slot (scratch is only used inside a synced live composite).
        zero(s)
        return s
    }

    /// A zeroed scratch slot after the real ones.
    func scratch() -> UInt32 {
        precondition(count + scratchCount < capacity, "tile pool: grow before allocating scratch")
        let s = count + scratchCount
        scratchCount += 1
        zero(UInt32(s))
        return UInt32(s)
    }

    func releaseScratch() { scratchCount = 0 }

    func zero(_ s: UInt32) {
        let o = Int(s) * GPUTilePool.px * 4
        memset(cov.contents() + o, 0, GPUTilePool.px * 4)
        if let depth { memset(depth.contents() + o, 0, GPUTilePool.px * 4) }
        if let col { memset(col.contents() + o * nc, 0, GPUTilePool.px * 4 * nc) }
    }

    /// Encodes copies of slot `from` into slot `to` (all planes).
    func encodeCopy(_ blit: any MTLBlitCommandEncoder, from: UInt32, to: UInt32) {
        let n = GPUTilePool.px * 4
        blit.copy(from: cov, sourceOffset: Int(from) * n, to: cov, destinationOffset: Int(to) * n, size: n)
        if let depth { blit.copy(from: depth, sourceOffset: Int(from) * n, to: depth, destinationOffset: Int(to) * n, size: n) }
        if let col { blit.copy(from: col, sourceOffset: Int(from) * n * nc, to: col, destinationOffset: Int(to) * n * nc, size: n * nc) }
    }

    /// CPU copy of a slot (after GPU work completes).
    func read(_ s: UInt32) -> CovTile {
        let p = GPUTilePool.px
        func grab(_ b: (any MTLBuffer)?, _ per: Int) -> [Float] {
            guard let b else { return [] }
            let ptr = b.contents().bindMemory(to: Float.self, capacity: (Int(s) + 1) * p * per) + Int(s) * p * per
            return Array(UnsafeBufferPointer(start: ptr, count: p * per))
        }
        return CovTile(cov: grab(cov, 1), depth: grab(depth, 1), col: grab(col, nc))
    }
}

// MARK: Renderer

/// Incremental stroke rendering on the GPU. The API mirrors `StrokeRenderer`; `passes > 1` paints
/// symmetry passes merged under one opacity ceiling (`StrokeRenderer.compositeUnionMany`), and
/// `compositeLive` adds the smoothing-tail preview a canvas shows while the pointer is down
/// (`StrokeRenderer.compositeUnionLive`).
public final class MetalStrokeRenderer {
    public let ctx: BrushContext
    public let format: PixelFormat
    /// Symmetry passes (1…4).
    public let passes: Int
    let metal: MetalContext
    let accumulatePSO: any MTLComputePipelineState
    let compositePSO: any MTLComputePipelineState
    var generators: [DabGenerator]
    let perDabColor: Bool
    let nc: Int
    let wet: Bool
    let pool: GPUTilePool
    let dualPool: GPUTilePool?
    var passBounds: [PixelRect]
    var dirty = Set<CovKey>()
    var dualDirty = Set<CovKey>()
    /// Primary dabs of the first pass.
    public private(set) var dabCount = 0
    var pending: (any MTLCommandBuffer)?
    // Static resources.
    let tipMips: any MTLBuffer, tipLevels: any MTLBuffer
    let dualMips: any MTLBuffer, dualLevels: any MTLBuffer
    let pattern: any MTLBuffer
    let rasterPrimary: PcpRaster
    let rasterDual: PcpRaster
    var stage: (any MTLBuffer)?
    var selStage: (any MTLBuffer)?
    // Live tail preview state.
    var liveTailKeys = Set<CovKey>()
    var liveBounds = PixelRect.empty
    /// Keep every primary dab of the first pass (tests, sequential tools).
    public var recordDabs = false
    public private(set) var dabs: [Dab] = []
    /// Composites that fell back to the CPU (non-Normal modes in CMYK/Lab).
    public private(set) var cpuCompositeFallbacks = 0

    static func library(_ m: MetalContext) throws -> any MTLLibrary {
        try m.library(key: "pcpaint.shaders.v2", includeFoundation: false) {
            // No FMA contraction anywhere (PCBlend included): the CPU reference doesn't fuse either.
            "#pragma METAL fp contract(off)\n" + MetalContext.foundationShaderSource + "\n" + MetalContext.shaderSource(bundle: .module)
        }
    }

    /// `format` = target pixel format; `zoom` for smoothing; `passes` = symmetry passes (1…4).
    public init(_ brush: BrushSettings, format: PixelFormat, zoom: Float = 1, passes: Int = 1,
                context: MetalContext? = MetalContext.shared) throws {
        guard let m = context else { throw MetalPaintError.noMetal }
        if format.channels > 8 { throw MetalPaintError.tooManyChannels(format.channels) }
        precondition((1...4).contains(passes), "1…4 symmetry passes")
        metal = m
        self.passes = passes
        let lib = try MetalStrokeRenderer.library(m)
        accumulatePSO = try m.pipeline("pcp_accumulate", in: lib)
        compositePSO = try m.pipeline("pcp_composite", in: lib)
        ctx = BrushContext(brush)
        self.format = format
        generators = Array(repeating: DabGenerator(brush: brush, zoom: zoom), count: passes)
        passBounds = Array(repeating: .empty, count: passes)
        perDabColor = brush.colorDynamics.enabled && !brush.erase
        nc = perDabColor ? format.mode.colorChannels : 0
        wet = ctx.brush.wetEdges
        pool = try GPUTilePool(device: m.device, nc: nc, wantDepth: wet)
        dualPool = ctx.brush.dualBrush.enabled ? try GPUTilePool(device: m.device, nc: 0, wantDepth: false) : nil
        func upload(_ mips: Mips?) throws -> (any MTLBuffer, any MTLBuffer) {
            var data: [Float] = []
            var levels: [SIMD4<UInt32>] = []
            for l in mips?.levels ?? [] {
                levels.append(SIMD4(UInt32(data.count), UInt32(l.w), UInt32(l.h), 0))
                data.append(contentsOf: l.v)
            }
            if data.isEmpty { data = [0]; levels = [SIMD4(0, 1, 1, 0)] }
            guard let d = m.device.makeBuffer(bytes: data, length: data.count * 4, options: .storageModeShared),
                  let l = m.device.makeBuffer(bytes: levels, length: levels.count * 16, options: .storageModeShared) else {
                throw MetalPaintError.allocation("tip mips")
            }
            return (d, l)
        }
        (tipMips, tipLevels) = try upload(ctx.tip)
        (dualMips, dualLevels) = try upload(ctx.dualTip)
        let pat = ctx.texture?.data ?? [1]
        guard let pb = m.device.makeBuffer(bytes: pat, length: pat.count * 4, options: .storageModeShared) else {
            throw MetalPaintError.allocation("pattern")
        }
        pattern = pb
        let b = ctx.brush
        var rp = PcpRaster()
        rp.hardness = b.hardness
        rp.aliased = b.aliased ? 1 : 0
        rp.square = (b.aliased && b.square) ? 1 : 0
        rp.noise = b.noise ? 1 : 0
        rp.texTip = (b.texture.enabled && b.texture.eachTip && ctx.texture != nil) ? 1 : 0
        rp.wantDepth = wet ? 1 : 0
        rp.wantCol = nc > 0 ? 1 : 0
        rp.sampled = ctx.tip != nil ? 1 : 0
        rp.nc = UInt32(nc)
        rp.texMode = b.texture.mode.gpuIndex
        rp.patW = UInt32(ctx.texture?.width ?? 1)
        rp.patH = UInt32(ctx.texture?.height ?? 1)
        rp.texScale = ctx.texScale
        rasterPrimary = rp
        var rd = PcpRaster()
        rd.hardness = b.dualBrush.hardness
        rd.sampled = ctx.dualTip != nil ? 1 : 0
        rasterDual = rd
    }

    /// Union of the dab rectangles of every pass so far.
    public var bounds: PixelRect { passBounds.reduce(.empty) { $0.union($1) } }
    public var wantsTime: Bool { generators[0].wantsTime }
    public var smoothingString: (brush: SIMD2<Double>, pointer: SIMD2<Double>)? { generators[0].smoothingString }

    /// Feed input points to the first (only) pass (any chunking gives the same result). Encodes GPU
    /// work; nothing waits until a composite or a read.
    public func push(_ pts: [StrokePoint]) throws { try push(passes: [pts]) }

    /// Feed each symmetry pass its points (the stroke, then its mirrors).
    public func push(passes pts: [[StrokePoint]]) throws {
        precondition(pts.count <= passes, "more point lists than passes")
        for (p, list) in pts.enumerated() {
            var d: [Dab] = [], du: [Dab] = []
            generators[p].push(list, &d, &du)
            try raster(pass: p, d, du)
        }
    }

    /// End of stroke (smoothing catch-up, a lone first point) for every pass.
    public func finish() throws {
        for p in 0..<passes {
            var d: [Dab] = [], du: [Dab] = []
            generators[p].finish(&d, &du)
            try raster(pass: p, d, du)
        }
    }

    func raster(pass p: Int, _ d: [Dab], _ du: [Dab]) throws {
        for x in d { passBounds[p] = passBounds[p].union(ctx.dabRect(x, dual: false)) }
        if p == 0 {
            dabCount += d.count
            if recordDabs { dabs.append(contentsOf: d) }
        }
        dirty.formUnion(try encodeDabs(d, dual: false, pool: pool, pass: p, slotFor: nil))
        if let dp = dualPool { dualDirty.formUnion(try encodeDabs(du, dual: true, pool: dp, pass: p, slotFor: nil)) }
    }

    func commandBuffer() throws -> any MTLCommandBuffer {
        if let p = pending { return p }
        guard let cb = metal.queue.makeCommandBuffer() else { throw MetalContextError.commandBufferFailed("makeCommandBuffer") }
        cb.label = "pcpaint.stroke"
        pending = cb
        return cb
    }

    /// Commit pending GPU work and wait for it.
    public func sync() throws {
        guard let cb = pending else { return }
        pending = nil
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw MetalContextError.commandBufferFailed(e.localizedDescription) }
    }

    /// The GPU record of a dab, computed exactly as `BrushContext.rasterizeInto` sets up its loop.
    func gpuDab(_ d: Dab, dual: Bool, rect: PixelRect) -> PcpDab {
        let b = ctx.brush
        let aliased = b.aliased && !dual
        let mips = dual ? ctx.dualTip : ctx.tip
        var g = PcpDab()
        (g.cx, g.cy) = aliased ? gridCenter(d.center.x, d.center.y, 2 * d.radius) : (Float(d.center.x), Float(d.center.y))
        g.sn = sinf(d.angle); g.cs = cosf(d.angle)
        g.fx = d.flipX ? -1 : 1; g.fy = d.flipY ? -1 : 1
        if !dual && d.projScale < 0.999 {
            g.pax = cosf(d.projAngle); g.pay = sinf(d.projAngle); g.pk = 1 / maxR(d.projScale, 0.05) - 1
            g.flags |= 1
        }
        let r = d.radius
        g.r = r
        g.ro = minR(maxR(d.roundness, 0.5 / r), 1)
        g.rm = maxR(r * g.ro, 0.5)
        g.reach2 = (g.rm + 0.5) * (g.rm + 0.5)
        g.smallReach2 = (g.rm + 0.75) * (g.rm + 0.75)
        if let m = mips {
            let l0 = m.levels[0]
            g.level = UInt32(m.levelFor(2 * r * maxR(g.ro, 0.25)))
            g.invScale = Float(max(l0.w, l0.h)) / (2 * r)
            g.tw = Float(l0.w); g.th = Float(l0.h)
        }
        if mips == nil && !aliased && g.rm < smallTipRadius { g.flags |= 2 }
        g.alpha = d.alpha
        g.ceilv = dual ? 1 : d.opacity
        g.texDepth = d.depth
        g.x0 = rect.x0; g.y0 = rect.y0; g.x1 = rect.x1; g.y1 = rect.y1
        if !dual && nc > 0 {
            var native = [Float](repeating: 0, count: 8)
            native.withUnsafeMutableBufferPointer { _ = fromRGBA(format, d.color, into: $0.baseAddress!) }
            g.col = (native[0], native[1], native[2], native[3])
        }
        return g
    }

    /// Bins `ds` per coverage tile and encodes the accumulate kernel. `slotFor` maps keys to scratch
    /// slots (tail previews); nil allocates real slots of `pass`. Returns the touched keys.
    @discardableResult
    func encodeDabs(_ ds: [Dab], dual: Bool, pool: GPUTilePool, pass: Int, slotFor: [CovKey: UInt32]?) throws -> Set<CovKey> {
        if ds.isEmpty { return [] }
        var recs: [PcpDab] = []
        recs.reserveCapacity(ds.count)
        var bins: [CovKey: [UInt32]] = [:]
        for d in ds {
            let rect = ctx.dabRect(d, dual: dual)
            if rect.isEmpty { continue }
            let i = UInt32(recs.count)
            recs.append(gpuDab(d, dual: dual, rect: rect))
            for k in CovKey.keys(rect) { bins[k, default: []].append(i) }
        }
        if recs.isEmpty { return [] }
        let keys = bins.keys.sorted()
        if slotFor == nil {
            let need = pool.missing(pass, keys)
            if pool.count + pool.scratchCount + need > pool.capacity {
                try sync()
                try pool.grow(to: pool.count + pool.scratchCount + need)
            }
        }
        var jobs: [PcpJob] = []
        jobs.reserveCapacity(keys.count)
        var flat: [UInt32] = []
        for k in keys {
            let list = bins[k]!
            let slot = slotFor?[k] ?? pool.allocate(pass, k)
            jobs.append(PcpJob(slot: slot, tx: k.tx, ty: k.ty, binStart: UInt32(flat.count), binCount: UInt32(list.count)))
            flat.append(contentsOf: list)
        }
        let dev = metal.device
        guard let dabB = dev.makeBuffer(bytes: recs, length: recs.count * MemoryLayout<PcpDab>.stride, options: .storageModeShared),
              let binB = dev.makeBuffer(bytes: flat, length: flat.count * 4, options: .storageModeShared),
              let jobB = dev.makeBuffer(bytes: jobs, length: jobs.count * MemoryLayout<PcpJob>.stride, options: .storageModeShared) else {
            throw MetalPaintError.allocation("dab batch")
        }
        let cb = try commandBuffer()
        guard let enc = cb.makeComputeCommandEncoder() else { throw MetalContextError.commandBufferFailed("encoder") }
        enc.setComputePipelineState(accumulatePSO)
        enc.setBuffer(pool.cov, offset: 0, index: 0)
        enc.setBuffer(pool.depth ?? pool.cov, offset: 0, index: 1)
        enc.setBuffer(pool.col ?? pool.cov, offset: 0, index: 2)
        enc.setBuffer(dabB, offset: 0, index: 3)
        enc.setBuffer(binB, offset: 0, index: 4)
        enc.setBuffer(dual ? dualMips : tipMips, offset: 0, index: 7)
        enc.setBuffer(dual ? dualLevels : tipLevels, offset: 0, index: 8)
        enc.setBuffer(pattern, offset: 0, index: 9)
        let tg = min(256, accumulatePSO.maxTotalThreadsPerThreadgroup)
        let chunk = 32768
        var start = 0
        while start < jobs.count {
            let n = min(chunk, jobs.count - start)
            var u = dual ? rasterDual : rasterPrimary
            u.jobCount = UInt32(n)
            enc.setBuffer(jobB, offset: start * MemoryLayout<PcpJob>.stride, index: 5)
            enc.setBytes(&u, length: MemoryLayout<PcpRaster>.stride, index: 6)
            enc.dispatchThreads(MTLSize(width: GPUTilePool.px, height: n, depth: 1), threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
            start += n
        }
        enc.endEncoding()
        return Set(keys)
    }

    // MARK: Composite

    /// Can the composite kernel do this target? (Normal/Dissolve/erase in any model; other blend
    /// modes in RGB-like and Gray models.)
    func gpuComposites(_ fmt: PixelFormat) -> Bool {
        let b = ctx.brush
        if fmt.channels > 8 { return false }
        if b.erase || b.mode == .normal || b.mode == .dissolve { return true }
        return fmt.mode.isRGBLike || fmt.mode.isGrayLike
    }

    /// Per-pass (coverage, dual) slots of a key: −1 where the pass has no tile.
    typealias Slots = ([Int32], [Int32])

    func realSlots(_ k: CovKey) -> Slots {
        var c = [Int32](repeating: -1, count: passes), d = [Int32](repeating: -1, count: passes)
        for p in 0..<passes {
            if let s = pool.slot(p, k) { c[p] = Int32(s) }
            if let s = dualPool?.slot(p, k) { d[p] = Int32(s) }
        }
        return (c, d)
    }

    /// Composite the stroke buffer onto `target`, reading original pixels from `pre`. With
    /// `all = false` only tiles touched since the last composite are processed. Returns the damage.
    @discardableResult
    public func composite(pre: Surface, target: inout Surface, selection: Surface? = nil, lockTransparency: Bool = false, all: Bool) throws -> PixelRect {
        let keys = all ? pool.sortedKeys : dirty.sorted()
        dirty.removeAll()
        dualDirty.removeAll()
        let clip = bounds
        let dmg = try compositeKeys(keys, slots: realSlots, clip: clip, pre: pre, target: &target, selection: selection,
                                    lockTransparency: lockTransparency)
        return all ? clip : dmg
    }

    /// Live preview for a canvas: redraws the tiles changed since the last call plus what finishing
    /// the stroke now would add (the smoothing catch-up tail), leaving `target` exactly as
    /// `finish()` + `composite(all:)` would over the tiles drawn, and restoring the previous tail's
    /// pixels. `redrawAll` recomposites every tile. Returns the damaged rectangle.
    @discardableResult
    public func compositeLive(pre: Surface, target: inout Surface, selection: Surface? = nil, lockTransparency: Bool = false,
                              redrawAll: Bool = false) throws -> PixelRect {
        var keys = dirty
        if redrawAll { keys.formUnion(pool.sortedKeys) }
        let held = Set(pool.sortedKeys)
        for k in dualDirty where held.contains(k) { keys.insert(k) }
        dirty.removeAll()
        dualDirty.removeAll()
        var dmg = PixelRect.empty
        // Back to the pre-stroke pixels where the previous tail drew.
        for k in liveTailKeys {
            let r = k.rect.intersect(liveBounds)
            if r.isEmpty { continue }
            copyRegion(from: pre, to: &target, r)
            dmg = dmg.union(r)
            if held.contains(k) { keys.insert(k) }
        }
        // What finishing each pass now would add.
        var tails: [([Dab], [Dab])] = []
        var tailKeys: [Set<CovKey>] = []
        var allTailKeys = Set<CovKey>()
        var merged = PixelRect.empty
        for p in 0..<passes {
            var g = generators[p]
            var td: [Dab] = [], tdu: [Dab] = []
            g.finish(&td, &tdu)
            var tk = Set<CovKey>()
            var pb = passBounds[p]
            for d in td {
                let r = ctx.dabRect(d, dual: false)
                pb = pb.union(r)
                tk.formUnion(CovKey.keys(r))
            }
            for d in tdu { tk.formUnion(CovKey.keys(ctx.dabRect(d, dual: true))) }
            if td.isEmpty && tdu.isEmpty { tk = [] }
            merged = merged.union(pb)
            tails.append((td, tdu))
            tailKeys.append(tk)
            allTailKeys.formUnion(tk)
        }
        if allTailKeys.isEmpty {
            liveTailKeys = []
            liveBounds = merged
            let d = try compositeKeys(keys.sorted(), slots: realSlots, clip: merged, pre: pre, target: &target, selection: selection,
                                      lockTransparency: lockTransparency)
            return dmg.union(d)
        }
        // Copy the tiles each tail touches into scratch slots and render the tail there.
        try sync()
        let need = tailKeys.reduce(0) { $0 + $1.count }
        if pool.count + need > pool.capacity { try pool.grow(to: pool.count + need) }
        if let dp = dualPool, dp.count + need > dp.capacity { try dp.grow(to: dp.count + need) }
        var scratch: [[CovKey: UInt32]] = Array(repeating: [:], count: passes)
        var dualScratch: [[CovKey: UInt32]] = Array(repeating: [:], count: passes)
        let cb = try commandBuffer()
        guard let blit = cb.makeBlitCommandEncoder() else { throw MetalContextError.commandBufferFailed("blit") }
        for p in 0..<passes {
            for k in tailKeys[p].sorted() {
                let s = pool.scratch()
                if let real = pool.slot(p, k) { pool.encodeCopy(blit, from: real, to: s) }
                scratch[p][k] = s
                if let dp = dualPool {
                    let ds = dp.scratch()
                    if let real = dp.slot(p, k) { dp.encodeCopy(blit, from: real, to: ds) }
                    dualScratch[p][k] = ds
                }
            }
        }
        blit.endEncoding()
        for p in 0..<passes {
            try encodeDabs(tails[p].0, dual: false, pool: pool, pass: p, slotFor: scratch[p])
            if let dp = dualPool { try encodeDabs(tails[p].1, dual: true, pool: dp, pass: p, slotFor: dualScratch[p]) }
        }
        keys.formUnion(allTailKeys)
        func liveSlots(_ k: CovKey) -> Slots {
            var (c, d) = realSlots(k)
            for p in 0..<passes {
                if let s = scratch[p][k] { c[p] = Int32(s) }
                if let s = dualScratch[p][k] { d[p] = Int32(s) }
            }
            return (c, d)
        }
        let d = try compositeKeys(keys.sorted(), slots: liveSlots, clip: merged, pre: pre, target: &target, selection: selection,
                                  lockTransparency: lockTransparency)
        pool.releaseScratch()
        dualPool?.releaseScratch()
        liveTailKeys = allTailKeys
        liveBounds = merged
        return dmg.union(d)
    }

    func copyRegion(from pre: Surface, to target: inout Surface, _ r: PixelRect) {
        var region: [Float] = []
        pre.readRegionReusing(r, &region)
        target.writeRegionSafe(r, &region)
    }

    /// Composite `keys` (clipped to `clip`) with the per-pass slots `slots` gives.
    func compositeKeys(_ keys0: [CovKey], slots: (CovKey) -> Slots, clip: PixelRect, pre: Surface, target: inout Surface,
                       selection: Surface?, lockTransparency: Bool) throws -> PixelRect {
        var jobsIn: [(CovKey, Slots, PixelRect)] = []
        for k in keys0 {
            let s = slots(k)
            if !s.0.contains(where: { $0 >= 0 }) { continue }
            let r = k.rect.intersect(clip)
            if r.isEmpty { continue }
            jobsIn.append((k, s, r))
        }
        if jobsIn.isEmpty { try sync(); return .empty }
        let fmt = target.format
        if !gpuComposites(fmt) {
            // CPU composite from the GPU coverage: the passes' tiles merged as `unionMax` does.
            try sync()
            cpuCompositeFallbacks += 1
            var cm: CoverageMap?
            var dm: CoverageMap?
            for p in 0..<passes {
                var pc = CoverageMap(colorChannels: nc)
                var pd: CoverageMap? = dualPool != nil ? CoverageMap(colorChannels: 0) : nil
                for (k, s, _) in jobsIn {
                    if s.0[p] >= 0 { pc.tiles[k] = pool.read(UInt32(s.0[p])) }
                    if s.1[p] >= 0, let dp = dualPool { pd!.tiles[k] = dp.read(UInt32(s.1[p])) }
                }
                if cm == nil { cm = pc } else { cm!.unionMax(pc) }
                if let pd { if dm == nil { dm = pd } else { dm!.unionMax(pd) } }
            }
            return StrokeCompositor.composite(keys: jobsIn.map { $0.0 }, cov: cm!, dual: dm, ctx: ctx, perDabColor: perDabColor && nc > 0,
                                              bounds: clip, pre: pre, target: &target, selection: selection, lockTransparency: lockTransparency)
        }
        // Stage the pre-stroke surface tiles.
        var stageIndex: [TileCoord: UInt32] = [:]
        var stageTiles: [TileCoord] = []
        var cjobs: [PcpCJob] = []
        func four(_ a: [Int32]) -> (Int32, Int32, Int32, Int32) {
            (a.count > 0 ? a[0] : -1, a.count > 1 ? a[1] : -1, a.count > 2 ? a[2] : -1, a.count > 3 ? a[3] : -1)
        }
        for (k, s, r) in jobsIn {
            let tc = TileCoord(containing: k.rect.x0, k.rect.y0)
            let si: UInt32
            if let e = stageIndex[tc] { si = e } else {
                si = UInt32(stageTiles.count)
                stageIndex[tc] = si
                stageTiles.append(tc)
            }
            cjobs.append(PcpCJob(covSlots: four(s.0), dualSlots: four(s.1), stage: si, tx: k.tx, ty: k.ty, stx: tc.tx, sty: tc.ty,
                                 x0: r.x0, y0: r.y0, x1: r.x1, y1: r.y1))
        }
        let bpp = fmt.bytesPerPixel
        let tileBytes = Int(tileSize) * Int(tileSize) * bpp
        let stageLen = stageTiles.count * tileBytes
        if (stage?.length ?? 0) < stageLen {
            try sync()
            guard let b = metal.device.makeBuffer(length: max(stageLen, (stage?.length ?? 0) * 2), options: .storageModeShared) else {
                throw MetalPaintError.allocation("stage \(stageLen)")
            }
            stage = b
        }
        let st = stage!
        let defaultPixel = pre.defaultPixel
        let zeroDefault = defaultPixel.allSatisfy { $0 == 0 }
        for (i, tc) in stageTiles.enumerated() {
            let dst = st.contents() + i * tileBytes
            if let t = pre.tile(tc) {
                t.bytes.withUnsafeBytes { _ = memcpy(dst, $0.baseAddress!, tileBytes) }
            } else if zeroDefault {
                memset(dst, 0, tileBytes)
            } else {
                defaultPixel.withUnsafeBytes { dp in
                    for p in 0..<(tileBytes / bpp) { memcpy(dst + p * bpp, dp.baseAddress!, bpp) }
                }
            }
        }
        let tilePx = Int(tileSize) * Int(tileSize)
        if let sel = selection {
            let selLen = stageTiles.count * tilePx * 4
            if (selStage?.length ?? 0) < selLen {
                try sync()
                guard let b = metal.device.makeBuffer(length: max(selLen, (selStage?.length ?? 0) * 2), options: .storageModeShared) else {
                    throw MetalPaintError.allocation("selection stage")
                }
                selStage = b
            }
            let sp = selStage!.contents().bindMemory(to: Float.self, capacity: stageTiles.count * tilePx)
            for (i, tc) in stageTiles.enumerated() {
                let v = sel.readChannel0(tc.rect)
                v.withUnsafeBufferPointer { (sp + i * tilePx).update(from: $0.baseAddress!, count: tilePx) }
            }
        }
        // Uniforms.
        let b = ctx.brush
        var u = PcpComp()
        u.sample = fmt.sample == .u8 ? 0 : (fmt.sample == .u16 ? 1 : 2)
        u.channels = UInt32(fmt.channels)
        u.alphaIdx = alphaIndex(fmt).map { UInt32($0) } ?? .max
        u.nc = UInt32(fmt.mode.colorChannels)
        u.mode = b.mode.rawValue
        var flags: UInt32 = 0
        if b.erase { flags |= 1 }
        if lockTransparency { flags |= 2 }
        if fmt.sample == .u8 { flags |= 4 }
        if b.mode == .dissolve { flags |= 8 }
        if perDabColor && nc > 0 { flags |= 16 }
        if wet { flags |= 32 }
        if dualPool != nil { flags |= 64 }
        if ctx.strokeTexture { flags |= 128 }
        if selection != nil { flags |= 256 }
        if b.mode == .normal || b.mode == .dissolve { flags |= 512 }
        if fmt.mode.isGrayLike { flags |= 1024 }
        u.flags = flags
        u.opacity = clampR(b.opacity, 0, 1)
        u.seedLo = UInt32(truncatingIfNeeded: b.seed)
        u.seedHi = UInt32(truncatingIfNeeded: b.seed >> 32)
        u.dualMode = ctx.dualMode.gpuIndex
        u.texMode = ctx.texMode.gpuIndex
        u.texDepth = ctx.texDepth
        u.texScale = ctx.texScale
        u.patW = Int32(ctx.texture?.width ?? 1)
        u.patH = Int32(ctx.texture?.height ?? 1)
        u.passes = UInt32(passes)
        var src = [Float](repeating: 0, count: 8)
        src.withUnsafeMutableBufferPointer { _ = fromRGBA(fmt, b.color, into: $0.baseAddress!) }
        if let a = alphaIndex(fmt) { src[a] = b.color.w }
        u.src = (src[0], src[1], src[2], src[3], src[4], src[5], src[6], src[7])
        guard let jobB = metal.device.makeBuffer(bytes: cjobs, length: cjobs.count * MemoryLayout<PcpCJob>.stride, options: .storageModeShared) else {
            throw MetalPaintError.allocation("composite jobs")
        }
        let cb = try commandBuffer()
        guard let enc = cb.makeComputeCommandEncoder() else { throw MetalContextError.commandBufferFailed("encoder") }
        enc.setComputePipelineState(compositePSO)
        enc.setBuffer(st, offset: 0, index: 0)
        enc.setBuffer(st, offset: 0, index: 1)
        enc.setBuffer(st, offset: 0, index: 2)
        enc.setBuffer(pool.cov, offset: 0, index: 3)
        enc.setBuffer(pool.depth ?? pool.cov, offset: 0, index: 4)
        enc.setBuffer(pool.col ?? pool.cov, offset: 0, index: 5)
        enc.setBuffer(dualPool?.cov ?? pool.cov, offset: 0, index: 6)
        enc.setBuffer(selStage ?? pool.cov, offset: 0, index: 8)
        enc.setBuffer(pattern, offset: 0, index: 10)
        let tg = min(256, compositePSO.maxTotalThreadsPerThreadgroup)
        let chunk = 32768
        var start = 0
        while start < cjobs.count {
            let n = min(chunk, cjobs.count - start)
            u.jobCount = UInt32(n)
            enc.setBuffer(jobB, offset: start * MemoryLayout<PcpCJob>.stride, index: 7)
            enc.setBytes(&u, length: MemoryLayout<PcpComp>.stride, index: 9)
            enc.dispatchThreads(MTLSize(width: GPUTilePool.px, height: n, depth: 1), threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
            start += n
        }
        enc.endEncoding()
        try sync()
        // Copy the composited rows back into the target, one surface tile at a time.
        var byStage: [UInt32: [PixelRect]] = [:]
        var dmg = PixelRect.empty
        for (j, job) in cjobs.enumerated() {
            byStage[job.stage, default: []].append(jobsIn[j].2)
            dmg = dmg.union(jobsIn[j].2)
        }
        let ts = Int(tileSize)
        for (si, rects) in byStage {
            let tc = stageTiles[Int(si)]
            let src = UnsafeRawPointer(st.contents() + Int(si) * tileBytes)
            target.withTileBytes(tc) { p in
                for r in rects {
                    let span = r.width * bpp
                    for y in r.y0..<r.y1 {
                        let off = (Int(y - tc.ty * tileSize) * ts + Int(r.x0 - tc.tx * tileSize)) * bpp
                        memcpy(p.baseAddress! + off, src + off, span)
                    }
                }
            }
        }
        return dmg
    }

    // MARK: Readback

    /// One pass's raw stroke buffer as a CPU `CoverageMap` (coverage, depth, colour) plus its dual
    /// map, for parity tests and CPU consumers. Tiles allocated but never covered read as zeros.
    public func coverageMap(pass: Int = 0) throws -> (CoverageMap, CoverageMap?) {
        try sync()
        var m = CoverageMap(colorChannels: nc)
        for (pk, s) in pool.slots where pk.pass == pass { m.tiles[pk.key] = pool.read(s) }
        m.bounds = passBounds[pass]
        var d: CoverageMap?
        if let dp = dualPool {
            d = CoverageMap(colorChannels: 0)
            for (pk, s) in dp.slots where pk.pass == pass { d!.tiles[pk.key] = dp.read(s) }
        }
        return (m, d)
    }

    /// Every pass merged (`unionMax`, as the composite does).
    public func mergedCoverageMap() throws -> (CoverageMap, CoverageMap?) {
        var (m, d) = try coverageMap(pass: 0)
        for p in 1..<max(passes, 1) where p < passes {
            let (pm, pd) = try coverageMap(pass: p)
            m.unionMax(pm)
            if let pd { d?.unionMax(pd) }
        }
        m.dirty.removeAll()
        d?.dirty.removeAll()
        return (m, d)
    }

    /// Final stroke coverage at a pixel (stroke-level masks applied, before opacity/selection).
    public func coverageAt(_ x: Int32, _ y: Int32) throws -> Float {
        let (m, d) = try mergedCoverageMap()
        let c = m.get(x, y)
        if c <= 0 { return 0 }
        return ctx.strokeMaskWet(c, depth: m.depth(x, y), dual: d.map { $0.get(x, y) }, x, y)
    }

    /// Dense final coverage over the stroke bounds.
    public func denseCoverage() throws -> (PixelRect, [Float]) {
        let (m, d) = try mergedCoverageMap()
        let b = bounds
        let w = b.width
        var out = [Float](repeating: 0, count: w * b.height)
        for (key, t) in m.tiles {
            let tr = key.rect.intersect(b)
            if tr.isEmpty { continue }
            for y in tr.y0..<tr.y1 {
                for x in tr.x0..<tr.x1 {
                    let ti = Int((y - key.ty * covTile) * covTile + (x - key.tx * covTile))
                    let c = t.cov[ti]
                    if c > 0 {
                        out[Int(y - b.y0) * w + Int(x - b.x0)] =
                            ctx.strokeMaskWet(c, depth: ti < t.depth.count ? t.depth[ti] : nil, dual: d.map { $0.get(x, y) }, x, y)
                    }
                }
            }
        }
        return (b, out)
    }
}

/// Render a whole stroke onto `target` on the GPU (one-shot). Returns the damaged rectangle.
@discardableResult
public func renderStrokeMetal(_ target: inout Surface, _ brush: BrushSettings, _ points: [StrokePoint], selection: Surface? = nil,
                              lockTransparency: Bool = false, zoom: Float = 1, context: MetalContext? = MetalContext.shared) throws -> PixelRect {
    if points.isEmpty { return .empty }
    let pre = target
    let r = try MetalStrokeRenderer(brush, format: target.format, zoom: zoom, context: context)
    try r.push(points)
    try r.finish()
    return try r.composite(pre: pre, target: &target, selection: selection, lockTransparency: lockTransparency, all: true)
}
