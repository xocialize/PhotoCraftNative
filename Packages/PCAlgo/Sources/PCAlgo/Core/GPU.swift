// Port of photocraft-algo (crates/algo/src/lib.rs, the tile/halo contract), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Metal side of PCAlgo: the shader library (Shaders/*.metal, foundation's PCBlend.metal
// prepended), cached pipelines, float4 plane packing, and `GPUPass`, the encoder a filter's
// `encodeGPU` uses to dispatch its kernels.
//
// Plane layout: every image is uploaded as one or more `rgba32Float` planes. With alpha, a plane
// holds up to three colour channels in .xyz and alpha in .w (unused components are 0); without
// alpha, up to four colour channels. Gray+A is (g, 0, 0, a); RGBA is (r, g, b, a); CMYK+A is two
// planes, (c, m, y, a) and (k, 0, 0, a). Kernels see `frame.alpha` and treat .w accordingly.

import Foundation
import Metal
import PCFoundation
import Synchronization

/// Frame uniforms shared by every PCAlgo kernel (MSL `pca_frame`, buffer 0). Document
/// coordinates: texel (0, 0) of the source is `srcOrigin`, of the destination `outOrigin`.
public struct PCAFrame: BitwiseCopyable, Sendable {
    public var srcOrigin: SIMD2<Int32>
    public var srcSize: SIMD2<Int32>
    public var outOrigin: SIMD2<Int32>
    public var outSize: SIMD2<Int32>
    public var boundsOrigin: SIMD2<Int32>
    public var boundsSize: SIMD2<Int32>
    /// 1 when `.w` is alpha.
    public var alpha: UInt32
    /// 0 gray-like, 1 RGB-like, 2 other.
    public var mode: UInt32
    /// Colour components used in this plane.
    public var ncomp: UInt32
    /// Plane index.
    public var plane: UInt32
    /// Colour channels of the whole image.
    public var colorChannels: UInt32
    /// Image channel index of this plane's first colour component.
    public var firstChannel: UInt32
    public var pad0: UInt32 = 0
    public var pad1: UInt32 = 0

    /// This frame reading `src` and writing `out`.
    public func with(src: PixelRect? = nil, out: PixelRect? = nil) -> PCAFrame {
        var f = self
        if let s = src { f.srcOrigin = SIMD2(s.x0, s.y0); f.srcSize = SIMD2(Int32(s.width), Int32(s.height)) }
        if let o = out { f.outOrigin = SIMD2(o.x0, o.y0); f.outSize = SIMD2(Int32(o.width), Int32(o.height)) }
        return f
    }
}

/// How an image's channels map onto float4 planes.
struct PlaneLayout: Sendable {
    let channels: Int
    let alpha: Bool
    /// Image channel indices of each plane's colour components.
    let planes: [[Int]]

    init(channels: Int, alpha: Bool) {
        self.channels = channels
        self.alpha = alpha
        let cc = alpha ? channels - 1 : channels
        let per = alpha ? 3 : 4
        var p: [[Int]] = []
        var i = 0
        while i < cc { p.append(Array(i..<min(cc, i + per))); i += per }
        if p.isEmpty { p = [[]] }
        planes = p
    }

    /// The packed float4 data of plane `p`.
    func pack(_ img: FloatImage, plane p: Int, into dst: UnsafeMutablePointer<Float>) {
        let n = channels, count = img.rect.area
        let cols = planes[p]
        img.data.withUnsafeBufferPointer { s in
            if (alpha && n == 4 && cols == [0, 1, 2]) || (!alpha && n == 4 && cols == [0, 1, 2, 3]) {
                let d = UnsafeSendable(dst), base = UnsafeSendable(s.baseAddress!)
                parallelChunks(count * 4, minChunk: 1 << 20) { r in
                    (d.value + r.lowerBound).update(from: base.value + r.lowerBound, count: r.count)
                }
                return
            }
            let a = n - 1
            let d = UnsafeSendable(dst)
            parallelChunks(count, minChunk: 1 << 16) { r in
                for i in r {
                    let o = i * 4, si = i * n
                    var v = SIMD4<Float>(repeating: 0)
                    for (k, c) in cols.enumerated() { v[k] = s[si + c] }
                    if alpha { v[3] = s[si + a] }
                    d.value[o] = v.x; d.value[o + 1] = v.y; d.value[o + 2] = v.z; d.value[o + 3] = v.w
                }
            }
        }
    }

    /// Writes plane `p`'s float4 data into `img` (alpha from plane 0 only).
    func unpack(_ src: UnsafePointer<Float>, plane p: Int, into img: inout FloatImage) {
        let n = channels, count = img.rect.area
        let cols = planes[p]
        let writeAlpha = alpha && p == 0
        img.data.withUnsafeMutableBufferPointer { d in
            if (alpha && n == 4 && cols == [0, 1, 2]) || (!alpha && n == 4 && cols == [0, 1, 2, 3]) {
                let dd = UnsafeSendable(d.baseAddress!), base = UnsafeSendable(src)
                parallelChunks(count * 4, minChunk: 1 << 20) { r in
                    (dd.value + r.lowerBound).update(from: base.value + r.lowerBound, count: r.count)
                }
                return
            }
            let a = n - 1
            let dd = UnsafeSendable(d)
            parallelChunks(count, minChunk: 1 << 16) { r in
                for i in r {
                    let o = i * 4, di = i * n
                    for (k, c) in cols.enumerated() { dd.value[di + c] = src[o + k] }
                    if writeAlpha { dd.value[di + a] = src[o + 3] }
                }
            }
        }
    }
}

/// The PCAlgo shader library and pipeline cache on the shared Metal context.
public final class AlgoGPU: @unchecked Sendable {
    public let metal: MetalContext
    public let library: any MTLLibrary

    private static let instance: Result<AlgoGPU, FilterError> = {
        guard let m = MetalContext.shared else { return .failure(.gpuUnavailable("no Metal device")) }
        do {
            // Compiled here rather than through `MetalContext.library` so the transcendental
            // functions can be the precise ones (closer to libm, which the CPU references use);
            // `PCALGO_FAST_FUNCTIONS` switches back for comparison.
            let src = MetalContext.foundationShaderSource + "\n" + MetalContext.shaderSource(bundle: .module)
            let options = MTLCompileOptions()
            options.mathMode = .safe
            options.languageVersion = .version3_2
            options.mathFloatingPointFunctions = ProcessInfo.processInfo.environment["PCALGO_FAST_FUNCTIONS"] != nil ? .fast : .precise
            let lib = try m.device.makeLibrary(source: src, options: options)
            return .success(AlgoGPU(metal: m, library: lib))
        } catch {
            return .failure(.gpuUnavailable("PCAlgo shaders failed to compile: \(error)"))
        }
    }()

    /// The process-wide instance (throws if Metal or the shader library is unavailable).
    public static func shared() throws -> AlgoGPU { try instance.get() }

    /// Whether a Metal device and the PCAlgo library are available.
    public static var isAvailable: Bool { (try? shared()) != nil }

    init(metal: MetalContext, library: any MTLLibrary) {
        self.metal = metal; self.library = library
        textureCacheBudget = min(4 << 30, Int(metal.device.recommendedMaxWorkingSetSize / 4))
        pressure = MemoryPressureRelay.shared.register("PCAlgo reusable textures") { [weak self] in self?.trimCaches($0) ?? 0 }
        Self.settings.withLock { $0.live = self }
    }

    /// Keeps the reusable textures and staging buffers registered with `MemoryPressureRelay.shared`.
    private var pressure: MemoryPressureRegistration?

    /// The share of `memoryBudget` the cross-run cache may hold.
    public static let cacheShare = 0.05

    private struct Settings {
        var budget: Int?
        /// The instance, once something has made it (setting a budget doesn't compile the library).
        var live: AlgoGPU?
    }
    private static let settings = Mutex(Settings())

    /// The host's GPU memory budget in bytes (an engine's `memoryBudgetBytes`), for the process like
    /// the instance. It caps the cross-run cache, textures and staging buffers together, at
    /// `cacheShare` of it, and trims a fuller cache at once. nil (the default) keeps the caps from
    /// before: min(4 GiB, ¼ of the working set) of textures, and the four largest staging buffers.
    /// Setting it doesn't compile the shader library.
    public static var memoryBudget: Int? {
        get { settings.withLock { $0.budget } }
        set {
            let gpu = settings.withLock { (s: inout Settings) -> AlgoGPU? in
                s.budget = newValue.map { max($0, 0) }
                return s.live
            }
            gpu?.fitCache()
        }
    }

    /// Bytes the cross-run cache may hold now: `cacheShare` of `memoryBudget` for textures and
    /// staging buffers together; without a budget, min(4 GiB, ¼ of the working set) for textures.
    public var cacheLimit: Int { limit(Self.memoryBudget) }

    private func limit(_ budget: Int?) -> Int { budget.map { Int(Double($0) * Self.cacheShare) } ?? textureCacheBudget }

    /// Bytes of private textures and staging buffers kept for reuse across runs (GPU memory outside
    /// any canvas declaration; it counts in the process's footprint).
    public var cachedBytes: Int {
        cacheLock.withLock { textureCacheBytes + stagingBytes }
    }

    /// Trims the reusable textures (oldest first) to half on a warning; drops them and the staging
    /// buffers when critical. In-flight runs are unaffected (they hold their own). Returns the
    /// bytes freed. What it drops is let go of on a utility queue, so the call doesn't wait for
    /// Metal's deallocation (up to 23 ms for 2.9 GB under load); the memory follows a few
    /// milliseconds later.
    @discardableResult
    public func trimCaches(_ level: MemoryPressureRelay.Level) -> Int {
        var dropped: [AnyObject] = []
        cacheLock.lock()
        let held = textureCacheBytes + stagingBytes
        let target = level == .critical ? 0 : textureCacheBytes / 2
        while textureCacheBytes > target, !textureCache.isEmpty { dropped.append(dropOldestTexture()) }
        if level == .critical {
            dropped += staging.map { $0 as AnyObject }
            staging.removeAll()
        }
        let freed = held - (textureCacheBytes + stagingBytes)
        cacheLock.unlock()
        Self.discard(consume dropped)
        return freed
    }

    public var device: any MTLDevice { metal.device }

    /// Guards the cross-run cache: the textures and the staging buffers.
    private let cacheLock = NSLock()
    private var staging: [any MTLBuffer] = []
    private var stagingBytes: Int { staging.reduce(0) { $0 + $1.length } }

    /// A shared staging buffer of at least `length` bytes (reused across runs; contents undefined).
    func stagingBuffer(length: Int) throws -> any MTLBuffer {
        cacheLock.lock()
        if let i = staging.firstIndex(where: { $0.length >= length && $0.length <= 2 * length + (1 << 20) }) {
            let b = staging.remove(at: i)
            cacheLock.unlock()
            return b
        }
        cacheLock.unlock()
        guard let b = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
            throw FilterError.gpuUnavailable("staging buffer \(length)")
        }
        return b
    }

    /// Returns a staging buffer once the GPU and the CPU are done with it (keeps the four largest,
    /// within `cacheLimit` under a budget).
    func returnStaging(_ b: any MTLBuffer) {
        cacheLock.lock()
        staging.append(b)
        staging.sort { $0.length > $1.length }
        var dropped: [AnyObject] = []
        while staging.count > 4 { dropped.append(staging.removeLast()) }
        dropped += fitLocked()
        cacheLock.unlock()
        Self.discard(consume dropped)
    }

    public func pipeline(_ name: String, constants: MTLFunctionConstantValues? = nil, constantsKey: String = "") throws -> any MTLComputePipelineState {
        try metal.pipeline(name, in: library, constants: constants, constantsKey: constantsKey)
    }

    private var textureCache: [any MTLTexture] = []
    private var textureCacheBytes = 0
    /// Bytes of private textures kept for reuse across runs without a `memoryBudget` (fresh private
    /// textures must be zero-filled by the OS on first use, which costs more than many kernels).
    private let textureCacheBudget: Int

    /// A private float4 texture from the cross-run cache: exactly `width × height` when `exact`,
    /// else at least that size (and not much larger).
    func cachedTexture(width: Int, height: Int, exact: Bool) throws -> any MTLTexture {
        let w = max(width, 1), h = max(height, 1)
        cacheLock.lock()
        let i = textureCache.firstIndex { t in
            exact ? (t.width == w && t.height == h) : (t.width >= w && t.height >= h && t.width * t.height <= 2 * w * h + 4096)
        }
        if let i {
            let t = textureCache.remove(at: i)
            textureCacheBytes -= t.width * t.height * 16
            cacheLock.unlock()
            return t
        }
        cacheLock.unlock()
        return try privateTexture(width: w, height: h)
    }

    /// Hands textures back to the cross-run cache once their command buffer has completed.
    func releaseTextures(_ ts: [any MTLTexture]) {
        cacheLock.lock()
        for t in ts where !textureCache.contains(where: { $0 === t }) {
            textureCache.append(t)
            textureCacheBytes += t.width * t.height * 16
        }
        let dropped = fitLocked()
        cacheLock.unlock()
        Self.discard(consume dropped)
    }

    /// Trims the cache to `cacheLimit` (after a budget change).
    private func fitCache() {
        cacheLock.lock()
        let dropped = fitLocked()
        cacheLock.unlock()
        Self.discard(consume dropped)
    }

    /// Drops what the cache holds over `cacheLimit`: the oldest textures, then under a budget the
    /// smallest staging buffers. Returns them for `discard`, outside the lock.
    private func fitLocked() -> [AnyObject] {
        let budget = Self.memoryBudget, cap = limit(budget)
        var held: Int { textureCacheBytes + (budget == nil ? 0 : stagingBytes) }
        var dropped: [AnyObject] = []
        while held > cap, !textureCache.isEmpty { dropped.append(dropOldestTexture()) }
        while held > cap, !staging.isEmpty { dropped.append(staging.removeLast()) }
        return dropped
    }

    private func dropOldestTexture() -> any MTLTexture {
        let t = textureCache.removeFirst()
        textureCacheBytes -= t.width * t.height * 16
        return t
    }

    /// Where dropped textures and buffers are let go of: Metal's deallocation scales with the bytes,
    /// and whoever dropped them (an engine's shrink, a run's completion) shouldn't wait for it.
    private static let releaseQueue = DispatchQueue(label: "PCAlgo.AlgoGPU.releases", qos: .utility,
                                                    autoreleaseFrequency: .workItem)

    /// Lets go of `objects` on `releaseQueue`.
    private static func discard(_ objects: consuming [AnyObject]) {
        if objects.isEmpty { return }
        let dropped = Dropped(consume objects)
        releaseQueue.async { dropped.objects.removeAll() }
    }

    /// Dropped textures and buffers on their way to `releaseQueue`.
    private final class Dropped: @unchecked Sendable {
        var objects: [AnyObject]
        init(_ objects: consuming [AnyObject]) { self.objects = objects }
    }

    /// Waits until everything dropped so far has been let go of, so the device's allocation count
    /// follows (tests, benches; PCRender's `MetalCompositor.waitForReleases` likewise).
    public static func waitForReleases() { releaseQueue.sync {} }

    /// A private float4 texture (intermediate results).
    func privateTexture(width: Int, height: Int) throws -> any MTLTexture {
        guard let t = metal.makeTexture(width: width, height: height, pixelFormat: .rgba32Float,
                                        usage: [.shaderRead, .shaderWrite], storage: .private) else {
            throw FilterError.gpuUnavailable("makeTexture \(width)×\(height)")
        }
        return t
    }
}

/// One plane of one filter run on the GPU: the source texture (covering `srcRect`), the
/// destination texture (covering `out`), the frame uniforms, and helpers to allocate
/// intermediates and dispatch kernels into the run's command buffer.
///
/// Binding convention for kernels: `buffer(0)` frame, `buffer(1)` filter params, `buffer(2…)`
/// extra buffers; textures in the order given.
public final class GPUPass {
    public let gpu: AlgoGPU
    public let commandBuffer: any MTLCommandBuffer
    public let src: any MTLTexture
    public let dst: any MTLTexture
    public let frame: PCAFrame
    public let ctx: FilterContext
    public let srcRect: PixelRect
    public let out: PixelRect
    /// Plane index and the image channels it carries.
    public let plane: Int
    public let planeChannels: [Int]
    /// Intermediates handed back with `recycle`, reused by later `texture` calls of this plane.
    private var pool: [any MTLTexture] = []
    /// Every intermediate this pass handed out (returned to the cross-run cache after the run).
    private(set) var allocated: [any MTLTexture] = []

    init(gpu: AlgoGPU, commandBuffer: any MTLCommandBuffer, src: any MTLTexture, dst: any MTLTexture, frame: PCAFrame,
         ctx: FilterContext, srcRect: PixelRect, out: PixelRect, plane: Int, planeChannels: [Int]) {
        self.gpu = gpu; self.commandBuffer = commandBuffer; self.src = src; self.dst = dst; self.frame = frame
        self.ctx = ctx; self.srcRect = srcRect; self.out = out; self.plane = plane; self.planeChannels = planeChannels
    }

    /// A private float4 intermediate covering `rect`.
    public func texture(_ rect: PixelRect) throws -> any MTLTexture {
        try texture(width: rect.width, height: rect.height)
    }

    /// A private float4 intermediate of at least the given size (a recycled one when available:
    /// kernels address intermediates through their params, never through the texture's size).
    public func texture(width: Int, height: Int) throws -> any MTLTexture {
        let w = max(width, 1), h = max(height, 1)
        if let i = pool.firstIndex(where: { $0.width >= w && $0.height >= h && $0.width * $0.height <= 2 * w * h + 4096 }) {
            return pool.remove(at: i)
        }
        let t = try gpu.cachedTexture(width: w, height: h, exact: false)
        allocated.append(t)
        return t
    }

    /// Returns an intermediate for reuse by later passes of this plane. Encoders run in order and
    /// the textures are hazard-tracked, so a recycled texture is only overwritten after its last
    /// reader. Never recycle `src` or `dst`.
    public func recycle(_ t: any MTLTexture) {
        if t === src || t === dst { return }
        if pool.contains(where: { $0 === t }) { return }
        pool.append(t)
    }

    /// A shared buffer holding `values` (tables, kernels, per-pin data).
    public func buffer<T: BitwiseCopyable>(_ values: [T]) throws -> any MTLBuffer {
        let len = max(MemoryLayout<T>.stride * values.count, 16)
        let b: (any MTLBuffer)?
        if values.isEmpty { b = gpu.device.makeBuffer(length: len, options: .storageModeShared) }
        else { b = values.withUnsafeBytes { gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) } }
        guard let b else { throw FilterError.gpuUnavailable("makeBuffer \(len)") }
        return b
    }

    /// A private buffer of `length` bytes (GPU scratch; contents undefined — clear it in a kernel
    /// if the algorithm needs zeros).
    public func scratchBuffer(length: Int) throws -> any MTLBuffer {
        guard let b = gpu.device.makeBuffer(length: max(length, 16), options: .storageModePrivate) else {
            throw FilterError.gpuUnavailable("makeBuffer \(length)")
        }
        return b
    }

    /// Dispatches `kernel` over a `width × height` grid (16×16 threadgroups).
    public func dispatch<P: BitwiseCopyable>(_ kernel: String, frame f: PCAFrame? = nil, params: P,
                                             textures: [any MTLTexture], buffers: [any MTLBuffer] = [],
                                             width: Int, height: Int, threadgroup: (Int, Int) = (16, 16),
                                             threadgroupMemory: [Int] = []) throws {
        if width <= 0 || height <= 0 { return }
        let p = try gpu.pipeline(kernel)
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { throw FilterError.gpuUnavailable("encoder") }
        enc.label = kernel
        enc.setComputePipelineState(p)
        var fr = f ?? frame
        enc.setBytes(&fr, length: MemoryLayout<PCAFrame>.stride, index: 0)
        withUnsafeBytes(of: params) { b in
            if b.count > 0 { enc.setBytes(b.baseAddress!, length: b.count, index: 1) }
        }
        for (i, b) in buffers.enumerated() { enc.setBuffer(b, offset: 0, index: 2 + i) }
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        for (i, len) in threadgroupMemory.enumerated() { enc.setThreadgroupMemoryLength((len + 15) / 16 * 16, index: i) }
        var tw = threadgroup.0, th = threadgroup.1
        while tw * th > p.maxTotalThreadsPerThreadgroup { if th > 1 { th /= 2 } else { tw /= 2 } }
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
    }

    /// `dispatch` over the output rectangle.
    public func dispatchOut<P: BitwiseCopyable>(_ kernel: String, params: P, textures: [any MTLTexture]? = nil,
                                                buffers: [any MTLBuffer] = []) throws {
        try dispatch(kernel, params: params, textures: textures ?? [src, dst], buffers: buffers, width: out.width, height: out.height)
    }

    /// Copies a texture region (blit).
    public func copy(_ from: any MTLTexture, origin: (Int, Int) = (0, 0), size: (Int, Int), to: any MTLTexture, at: (Int, Int) = (0, 0)) throws {
        guard let b = commandBuffer.makeBlitCommandEncoder() else { throw FilterError.gpuUnavailable("blit") }
        b.copy(from: from, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: origin.0, y: origin.1, z: 0),
               sourceSize: MTLSize(width: size.0, height: size.1, depth: 1), to: to, destinationSlice: 0, destinationLevel: 0,
               destinationOrigin: MTLOrigin(x: at.0, y: at.1, z: 0))
        b.endEncoding()
    }
}

extension GPUPass {
    /// A pass for kernels that don't read a filter source (reductions, merges, non-filter
    /// operations): its frame describes `rect` as both source and output; `src`/`dst` are 1×1
    /// placeholders. Encode into `commandBuffer`, e.g. inside `gpu.metal.run { cb in … }`.
    public static func synthetic(_ gpu: AlgoGPU, _ commandBuffer: any MTLCommandBuffer, rect: PixelRect,
                                 context: FilterContext? = nil) throws -> GPUPass {
        let ph = try gpu.privateTexture(width: 1, height: 1)
        let ctx = context ?? FilterContext(bounds: rect, mode: .rgb, alpha: true)
        let o = SIMD2(rect.x0, rect.y0), s = SIMD2(Int32(rect.width), Int32(rect.height))
        let frame = PCAFrame(srcOrigin: o, srcSize: s, outOrigin: o, outSize: s, boundsOrigin: SIMD2(ctx.bounds.x0, ctx.bounds.y0),
                             boundsSize: SIMD2(Int32(ctx.bounds.width), Int32(ctx.bounds.height)), alpha: ctx.alpha ? 1 : 0,
                             mode: ctx.gpuModeCode, ncomp: 3, plane: 0, colorChannels: 3, firstChannel: 0)
        return GPUPass(gpu: gpu, commandBuffer: commandBuffer, src: ph, dst: ph, frame: frame, ctx: ctx,
                       srcRect: rect, out: rect, plane: 0, planeChannels: [0, 1, 2])
    }
}

/// Uniform-less kernels pass this as their params.
public struct NoParams: BitwiseCopyable, Sendable { public init() {}; var pad: UInt32 = 0 }
