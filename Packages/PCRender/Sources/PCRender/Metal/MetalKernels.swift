// Port of photocraft-gpu (crates/gpu/src/lib.rs pipelines, `op_words`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The PCRender Metal library: compiled once from Shaders/*.metal (foundation's PCBlend.metal
// prepended), compute pipelines cached per kernel and per function-constant specialisation, the
// per-dispatch uniform record `PCROp` (byte-for-byte the MSL struct) and dispatch helpers.

import Foundation
import Metal
import PCFoundation

/// The uniform record of one dispatch (MSL `PCROp`, 288 bytes).
struct PCROp {
    var origin = SIMD2<Int32>.zero
    var offset = SIMD2<Int32>.zero
    var size = SIMD2<Int32>.zero
    var mode: UInt32 = BlendMode.normal.rawValue
    var flags: UInt32 = 0
    var opacity: Float = 1
    var fill: Float = 1
    var gamma: Float = 1
    var density: Float = 1
    var maskOrigin = SIMD2<Int32>.zero
    var maskSize = SIMD2<Int32>.zero
    var vmaskOrigin = SIMD2<Int32>.zero
    var vmaskSize = SIMD2<Int32>.zero
    var maskDefault: Float = 1
    var vmaskOutside: Float = 1
    var leafOrigin = SIMD2<Int32>.zero
    var leafSize = SIMD2<Int32>.zero
    var mapOrigin = SIMD2<Int32>.zero
    var mapSize = SIMD2<Int32>.zero
    var aux = SIMD2<Int32>.zero
    var leafOutside = SIMD4<Float>.zero
    var color = SIMD4<Float>.zero
    var p0 = SIMD4<Float>.zero
    var p1 = SIMD4<Float>.zero
    var p2 = SIMD4<Float>.zero
    var p3 = SIMD4<Float>.zero
    var p4 = SIMD4<Float>.zero
    var p5 = SIMD4<Float>.zero
    var p6 = SIMD4<Float>.zero
    var p7 = SIMD4<Float>.zero

    static let flagMask: UInt32 = 1, flagVMask: UInt32 = 2, flagCombined: UInt32 = 4, flagDensity: UInt32 = 8, flagLeaf: UInt32 = 16
    static let flagLab: UInt32 = 32, flagHDR: UInt32 = 64, flagAtop: UInt32 = 128, flagOwn: UInt32 = 256, flagChannels: UInt32 = 512
    static let flagBlendIf: UInt32 = 1024, flagRGBMode: UInt32 = 2048, flagClipAlpha: UInt32 = 4096, flagDither: UInt32 = 8192
    static let flagQuant: UInt32 = 16384
    // Effect flags (PCR5Effects.metal)
    static let fxKnock: UInt32 = 1 << 16, fxShapeless: UInt32 = 1 << 17, fxOutline: UInt32 = 1 << 18, fxVStroke: UInt32 = 1 << 19
    static let fxRelative: UInt32 = 1 << 20, fxShapeAlpha: UInt32 = 1 << 21, fxFirst: UInt32 = 1 << 22, fxVector: UInt32 = 1 << 23
    static let fxNoPaint: UInt32 = 1 << 24, fxSplit: UInt32 = 1 << 28
    // Native blend spaces (PCR0Common.metal `pcr_sp`).
    static let flagNativeLab: UInt32 = 1 << 25, flagKPlane: UInt32 = 1 << 26, flagPS8: UInt32 = 1 << 27
}

/// Bindings of the accumulator kernels.
enum Slot {
    static let a = 0, b = 1, c = 2, d = 3, mask = 4, vmask = 5, leaf = 6, out = 7, pattern = 8, out2 = 9, cover = 10
}

/// Compiled kernels, dummies for unbound slots and pipeline lookup.
final class PCRKernels: @unchecked Sendable {
    let ctx: MetalContext
    let library: any MTLLibrary
    /// A 1×1 texture bound to every unused read slot.
    let dummy: any MTLTexture
    let dummy3D: any MTLTexture
    let linearSampler: any MTLSamplerState

    init(context: MetalContext) throws {
        ctx = context
        library = try context.library(bundle: .module, key: "PCRender")
        guard let d = context.makeTexture(width: 1, height: 1, pixelFormat: .rgba32Float, usage: [.shaderRead]) else {
            throw MetalContextError.commandBufferFailed("dummy texture")
        }
        dummy = d
        let d3 = MTLTextureDescriptor()
        d3.textureType = .type3D
        d3.pixelFormat = .rgba32Float
        d3.width = 2; d3.height = 2; d3.depth = 2
        d3.usage = [.shaderRead]
        guard let t3 = context.device.makeTexture(descriptor: d3) else { throw MetalContextError.commandBufferFailed("dummy 3D texture") }
        dummy3D = t3
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge; sd.rAddressMode = .clampToEdge
        guard let s = context.device.makeSamplerState(descriptor: sd) else { throw MetalContextError.commandBufferFailed("sampler") }
        linearSampler = s
    }

    func pipeline(_ name: String) throws -> any MTLComputePipelineState {
        try ctx.pipeline(name, in: library)
    }

    /// The adjust kernel specialised for adjustment `kind`.
    func adjustPipeline(_ kind: UInt32) throws -> any MTLComputePipelineState {
        let c = MTLFunctionConstantValues()
        var k = kind
        c.setConstantValue(&k, type: .uint, index: 0)
        return try ctx.pipeline("pcr_adjust", in: library, constants: c, constantsKey: "kind\(kind)")
    }

    /// Encodes `pipeline` over `grid` threads with `op` in buffer 0 and the given textures / buffers
    /// (every texture slot up to 10 bound, dummies where unused).
    func dispatch(_ enc: any MTLComputeCommandEncoder, _ pipeline: any MTLComputePipelineState, op: PCROp, grid: (Int, Int),
                  textures: [Int: any MTLTexture] = [:], buffers: [Int: any MTLBuffer] = [:]) {
        if grid.0 <= 0 || grid.1 <= 0 { return }
        var o = op
        enc.setBytes(&o, length: MemoryLayout<PCROp>.stride, index: 0)
        for i in 0...10 { enc.setTexture(textures[i] ?? dummy, index: i) }
        for (i, b) in buffers { enc.setBuffer(b, offset: 0, index: i) }
        MetalContext.dispatch2D(enc, pipeline, width: grid.0, height: grid.1)
    }

    /// A buffer holding `values` (at least 16 bytes).
    func buffer<T>(_ values: [T]) -> (any MTLBuffer)? {
        let len = max(16, values.count * MemoryLayout<T>.stride)
        if values.isEmpty { return ctx.device.makeBuffer(length: len, options: .storageModeShared) }
        return values.withUnsafeBytes { ctx.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }
}

/// Accumulator texture precision.
public enum AccumulatorPrecision: Sendable, Hashable {
    /// rgba16Float for 8-bit documents, rgba32Float for 16- and 32-bit ones, and for 8-bit plans
    /// that amplify small differences (see `amplifies`): half-float storage of 8-bit levels is off
    /// by up to 0.03 level, which a level-quantised adjustment chain or a dividing / thresholding
    /// blend turns into whole levels (measured: 6 levels after five adjustment layers).
    case automatic
    case half
    case float

    func format(for depth: SampleType) -> MTLPixelFormat {
        switch self {
        case .half: .rgba16Float
        case .float: .rgba32Float
        case .automatic: depth == .u8 ? .rgba16Float : .rgba32Float
        }
    }

    func format(for plan: RenderPlan) -> MTLPixelFormat {
        // Native Lab / CMYK plans are rounded to the document's levels and then converted for
        // display, which turns a half-float rounding into whole display levels (ps-corpus
        // mode-lab-8: 4.6 % of pixels off in half, 1.0 % in float).
        if self == .automatic && plan.context.depth == .u8 && (plan.context.native != .none || AccumulatorPrecision.amplifies(plan)) {
            return .rgba32Float
        }
        return format(for: plan.context.depth)
    }

    /// Modes whose result magnifies a half-float rounding of their inputs into whole 8-bit levels:
    /// Color Dodge / Burn and Vivid Light divide by `1 − c` or `c`, Divide by the source, Hard Mix
    /// and Dissolve threshold, Paint.NET Reflect / Glow divide. Adjustments (rounded to whole levels
    /// after each layer) count too. Measured in half: every other mode ≤ 0.6 level.
    static func amplifies(_ m: BlendMode) -> Bool {
        switch m {
        case .colorDodge, .colorBurn, .vividLight, .divide, .hardMix, .dissolve, .reflect, .glow, .paintNetColorBurn, .paintNetColorDodge: true
        default: false
        }
    }

    static func amplifies(_ plan: RenderPlan) -> Bool {
        for op in plan.ops {
            switch op {
            case .composite(let b), .clipped(let b): if amplifies(b.mode) { return true }
            case .adjustMix(let a): if amplifies(a.mode) { return true }
            case .adjust, .quantize: return true
            case .effect(let spec, _):
                if amplifies(spec.blend) { return true }
                for e in spec.effects.items where e.isEnabled {
                    switch e {
                    case .dropShadow(let s), .innerShadow(let s): if amplifies(s.common.blend) { return true }
                    case .outerGlow(let g), .innerGlow(let g): if amplifies(g.common.blend) { return true }
                    case .stroke(let s): if amplifies(s.common.blend) { return true }
                    case .colorOverlay(let o): if amplifies(o.common.blend) { return true }
                    case .gradientOverlay(let o): if amplifies(o.common.blend) { return true }
                    case .patternOverlay(let o): if amplifies(o.common.blend) { return true }
                    case .satin(let s): if amplifies(s.common.blend) { return true }
                    case .bevelEmboss(let b): if amplifies(b.highlight.blend) || amplifies(b.shadow.blend) { return true }
                    }
                }
            default: break
            }
        }
        return false
    }
}

/// A pool of same-sized textures reused across ops and chunks, placed in heaps (the transient
/// per-render working set).
final class TexturePool: @unchecked Sendable {
    let device: any MTLDevice
    private var free: [Key: [any MTLTexture]] = [:]
    private var heaps: [any MTLHeap] = []
    private(set) var allocatedBytes = 0

    struct Key: Hashable { let w: Int, h: Int, format: MTLPixelFormat.RawValue }

    init(device: any MTLDevice) { self.device = device }

    private func descriptor(_ w: Int, _ h: Int, _ format: MTLPixelFormat) -> MTLTextureDescriptor {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, w), height: max(1, h), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return d
    }

    func take(_ w: Int, _ h: Int, _ format: MTLPixelFormat) -> any MTLTexture {
        let key = Key(w: w, h: h, format: format.rawValue)
        if var list = free[key], let t = list.popLast() { free[key] = list; return t }
        let d = descriptor(w, h, format)
        for heap in heaps {
            if let t = heap.makeTexture(descriptor: d) { return t }
        }
        // A new heap for a batch of eight such textures.
        let sa = device.heapTextureSizeAndAlign(descriptor: d)
        let hd = MTLHeapDescriptor()
        hd.storageMode = .private
        hd.hazardTrackingMode = .tracked
        hd.size = (sa.size + sa.align) * 8
        if let heap = device.makeHeap(descriptor: hd), let t = heap.makeTexture(descriptor: d) {
            heaps.append(heap)
            allocatedBytes += hd.size
            return t
        }
        return device.makeTexture(descriptor: d)!
    }

    func give(_ t: any MTLTexture) {
        free[Key(w: t.width, h: t.height, format: t.pixelFormat.rawValue), default: []].append(t)
    }

    func purge() { free.removeAll(); heaps.removeAll(); allocatedBytes = 0 }
}
