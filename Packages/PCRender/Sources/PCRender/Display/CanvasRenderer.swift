// Port of photocraft-gpu (crates/gpu/src/lib.rs display sink) and the engine's display transform (docs/architecture.md §7.3), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Reduction-chain level selection adapted from Compositor v1.5 (Compositor/Rendering/DownsampleCache.swift, GPUCanvas.swift), MIT, © 2026 Wonder Assembly LLC.
//
// The canvas display path: a composite texture (from `MetalCompositor.render`) drawn into an
// MTKView drawable, a CAMetalLayer drawable or any texture, placed by a zoom / pan transform, over a
// checkerboard, with nearest sampling from 100 % up and bilinear (premultiplied) sampling below it,
// from a 2× area-averaged reduction chain past 50 % — then the 33³ display LUT (document profile →
// monitor, baked by PCPlatform's ColorSync code) as the final step.

import Foundation
import Metal
import MetalKit
import PCFoundation

/// Document → view placement: view pixel = document pixel × zoom + translate.
public struct CanvasViewTransform: Hashable, Sendable {
    public var zoom: Double
    public var translate: SIMD2<Double>
    public init(zoom: Double = 1, translate: SIMD2<Double> = .zero) { self.zoom = zoom; self.translate = translate }

    /// Reductions (halvings) to draw from at this zoom: the most that keep the copy at least as large
    /// as the screen (none from 50 % up).
    public var level: Int {
        guard zoom.isFinite, zoom > 0, zoom < 0.5 else { return 0 }
        return min(CanvasRenderer.maxLevel, Int(floor(log2(1 / zoom))))
    }

    /// Nearest sampling from 100 % up (pixels stay sharp squares).
    public var nearest: Bool { zoom >= 1 }
}

/// A 3D display LUT (`size`³ RGB entries, red fastest), sampled trilinearly in the final pass.
public struct DisplayLUT: @unchecked Sendable {
    public let size: Int
    public let texture: any MTLTexture

    /// `values`: size³ entries of encoded output RGB for encoded input RGB at grid points (red fastest).
    public init?(device: any MTLDevice, size: Int = 33, values: [SIMD3<Float>]) {
        guard size >= 2, values.count == size * size * size else { return nil }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float
        d.width = size; d.height = size; d.depth = size
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        let px = values.map { SIMD4($0, 1) }
        px.withUnsafeBytes {
            t.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                      bytesPerRow: size * 16, bytesPerImage: size * size * 16)
        }
        self.size = size
        texture = t
    }

    /// A LUT from a transform function (identity tests, proof previews).
    public init?(device: any MTLDevice, size: Int = 33, _ f: (SIMD3<Float>) -> SIMD3<Float>) {
        var v: [SIMD3<Float>] = []
        v.reserveCapacity(size * size * size)
        let m = Float(size - 1)
        for b in 0..<size { for g in 0..<size { for r in 0..<size { v.append(f(SIMD3(Float(r), Float(g), Float(b)) / m)) } } }
        self.init(device: device, size: size, values: v)
    }
}

/// Display uniforms (MSL `PCRDisplay`).
struct PCRDisplayUniforms {
    var translate = SIMD2<Float>.zero
    var zoom: Float = 1
    var levelScale: Float = 1
    var canvas = SIMD4<Int32>.zero
    var levelSize = SIMD2<Int32>.zero
    var checker: Float = 8
    var flags: UInt32 = 0
    var pasteboard = SIMD4<Float>(0.16, 0.16, 0.16, 1)
    var checkerA = SIMD4<Float>(1, 1, 1, 1)
    var checkerB = SIMD4<Float>(0.8, 0.8, 0.8, 1)
    var lutSize: Float = 33
    var pad = SIMD3<Float>.zero
}

/// Draws a composite to the screen.
public final class CanvasRenderer: @unchecked Sendable {
    public static let maxLevel = 10
    let kernels: PCRKernels
    let context: MetalContext
    public private(set) var composite: (any MTLTexture)?
    public private(set) var compositeRect: PixelRect = .empty
    /// Premultiplied 2× reductions of the composite (level 1…).
    private var levels: [any MTLTexture] = []
    public var view = CanvasViewTransform()
    public var displayLUT: DisplayLUT?
    /// Checkerboard square in view pixels.
    public var checkerSize: Float = 8
    public var pasteboard = SIMD4<Float>(0.16, 0.16, 0.16, 1)
    private var renderPipelines: [MTLPixelFormat.RawValue: any MTLRenderPipelineState] = [:]
    /// The compositor `show` last rendered through (told to forget this view on deinit).
    private weak var lastCompositor: MetalCompositor?

    public init(context: MetalContext? = MetalContext.shared) throws {
        guard let context else { throw MetalCompositorError.noMetal }
        self.context = context
        kernels = try PCRKernels(context: context)
    }

    deinit { lastCompositor?.forgetView(RenderView(self)) }

    /// This canvas as a view of the compositor: what its `show` renders use counts as visible.
    public var renderView: RenderView { RenderView(self) }

    /// What this canvas holds on the GPU (allocated bytes of the composite, its reduction chain and
    /// the LUT). Read it where the canvas is driven (it is not locked); a shrink never takes it.
    public var footprint: DisplayFootprint {
        var f = DisplayFootprint()
        f.composite = composite?.allocatedSize ?? 0
        f.levels = levels.reduce(0) { $0 + $1.allocatedSize }
        f.lut = displayLUT?.texture.allocatedSize ?? 0
        return f
    }

    /// Sets the composite (straight RGBA of `rect`) and rebuilds the reduction chain.
    public func setComposite(_ texture: any MTLTexture, rect: PixelRect) throws {
        composite = texture
        compositeRect = rect
        levels.removeAll()
        guard let cb = context.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw MetalCompositorError.gpu("display chain") }
        var src = texture
        var (w, h) = (texture.width, texture.height)
        for i in 1...CanvasRenderer.maxLevel {
            if w <= 1 && h <= 1 { break }
            (w, h) = ((w + 1) / 2, (h + 1) / 2)
            guard let dst = context.makeTexture(width: w, height: h, pixelFormat: .rgba16Float, usage: [.shaderRead, .shaderWrite], storage: .private) else { break }
            var op = PCROp()
            op.aux.x = i == 1 ? 1 : 0
            kernels.dispatch(enc, try kernels.pipeline("pcr_display_halve"), op: op, grid: (w, h), textures: [Slot.a: src, Slot.out: dst])
            levels.append(dst)
            src = dst
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    /// Composites `plan` with `compositor` and shows it (the usual refresh). The render is this
    /// canvas's view render: what it uses stays through a run-level shrink.
    public func show(_ plan: RenderPlan, region: PixelRect, source: any RenderSource, compositor: MetalCompositor) throws {
        if let old = lastCompositor, old !== compositor { old.forgetView(renderView) }
        lastCompositor = compositor
        let r = try compositor.render(plan, region: region, source: source, outputFormat: .rgba16Float, view: renderView)
        try setComposite(r.texture, rect: region)
    }

    func uniforms() -> (PCRDisplayUniforms, any MTLTexture)? {
        guard let composite else { return nil }
        let level = min(view.level, levels.count)
        let tex = level == 0 ? composite : levels[level - 1]
        var u = PCRDisplayUniforms()
        u.translate = SIMD2(Float(view.translate.x), Float(view.translate.y))
        u.zoom = Float(view.zoom)
        u.levelScale = Float(1 << level)
        u.canvas = SIMD4(compositeRect.x0, compositeRect.y0, compositeRect.x1, compositeRect.y1)
        u.levelSize = SIMD2(Int32(tex.width), Int32(tex.height))
        u.checker = checkerSize
        u.flags = (view.nearest && level == 0 ? 1 : 0) | (level > 0 ? 2 : 0) | (displayLUT != nil ? 4 : 0)
        u.pasteboard = pasteboard
        u.lutSize = Float(displayLUT?.size ?? 33)
        return (u, tex)
    }

    /// Draws into any texture (offscreen snapshots, tests) with a compute pass.
    public func encode(into cb: any MTLCommandBuffer, target: any MTLTexture) throws {
        guard let (u0, tex) = uniforms(), let enc = cb.makeComputeCommandEncoder() else { return }
        var u = u0
        let p = try kernels.pipeline("pcr_display_kernel")
        enc.setComputePipelineState(p)
        enc.setBytes(&u, length: MemoryLayout<PCRDisplayUniforms>.stride, index: 0)
        enc.setTexture(tex, index: 0)
        enc.setTexture(displayLUT?.texture ?? kernels.dummy3D, index: 1)
        enc.setTexture(target, index: 2)
        enc.setSamplerState(kernels.linearSampler, index: 0)
        MetalContext.dispatch2D(enc, p, width: target.width, height: target.height)
        enc.endEncoding()
    }

    private func renderPipeline(_ format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
        if let p = renderPipelines[format.rawValue] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = kernels.library.makeFunction(name: "pcr_display_vertex")
        d.fragmentFunction = kernels.library.makeFunction(name: "pcr_display_fragment")
        d.colorAttachments[0].pixelFormat = format
        let p = try context.device.makeRenderPipelineState(descriptor: d)
        renderPipelines[format.rawValue] = p
        return p
    }

    /// Draws into a render pass (an MTKView / CAMetalLayer drawable): one full-screen triangle.
    public func encode(into cb: any MTLCommandBuffer, pass: MTLRenderPassDescriptor, format: MTLPixelFormat) throws {
        guard let (u0, tex) = uniforms(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = u0
        enc.setRenderPipelineState(try renderPipeline(format))
        enc.setFragmentBytes(&u, length: MemoryLayout<PCRDisplayUniforms>.stride, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentTexture(displayLUT?.texture ?? kernels.dummy3D, index: 1)
        enc.setFragmentSamplerState(kernels.linearSampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Presents into a CAMetalLayer's next drawable.
    public func present(in layer: CAMetalLayer) throws {
        try autoreleasepool {
            guard let drawable = layer.nextDrawable(), let cb = context.queue.makeCommandBuffer() else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            try encode(into: cb, pass: pass, format: drawable.texture.pixelFormat)
            cb.present(drawable)
            cb.commit()
        }
    }
}

/// An MTKView delegate drawing a `CanvasRenderer` (on-demand redraw: set `enableSetNeedsDisplay`).
@MainActor public final class CanvasViewDelegate: NSObject, MTKViewDelegate {
    public let renderer: CanvasRenderer
    public init(renderer: CanvasRenderer) { self.renderer = renderer }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = renderer.context.queue.makeCommandBuffer() else { return }
        try? renderer.encode(into: cb, pass: pass, format: view.colorPixelFormat)
        cb.present(drawable)
        cb.commit()
    }
}

/// The CPU mirror of the display pass (tests): the colour of view pixel centre `pos`.
public enum CanvasDisplayMath {
    public static func shade(_ composite: RGBABuffer, view: CanvasViewTransform, pos: SIMD2<Float>, checker: Float = 8,
                             pasteboard: SIMD4<Float> = SIMD4(0.16, 0.16, 0.16, 1)) -> SIMD4<Float> {
        let doc = (pos - SIMD2(Float(view.translate.x), Float(view.translate.y))) / Float(view.zoom)
        let r = composite.rect
        if doc.x < Float(r.x0) || doc.y < Float(r.y0) || doc.x >= Float(r.x1) || doc.y >= Float(r.y1) { return pasteboard }
        func texel(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let p = composite.px[y * r.width + x]
            return SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w)
        }
        let tp = doc - SIMD2(Float(r.x0), Float(r.y0))
        var c: SIMD4<Float>
        if view.nearest {
            c = texel(Int(tp.x.rounded(.down)), Int(tp.y.rounded(.down)))
        } else {
            let f = tp - 0.5
            let i0 = SIMD2(f.x.rounded(.down), f.y.rounded(.down))
            let w = f - i0
            let ax = min(max(Int(i0.x), 0), r.width - 1), ay = min(max(Int(i0.y), 0), r.height - 1)
            let bx = min(max(Int(i0.x) + 1, 0), r.width - 1), by = min(max(Int(i0.y) + 1, 0), r.height - 1)
            let top = texel(ax, ay) + (texel(bx, ay) - texel(ax, ay)) * w.x
            let bot = texel(ax, by) + (texel(bx, by) - texel(ax, by)) * w.x
            c = top + (bot - top) * w.y
        }
        let cell = SIMD2(Int((pos.x / checker).rounded(.down)), Int((pos.y / checker).rounded(.down)))
        let ck: SIMD3<Float> = (cell.x + cell.y) & 1 == 0 ? SIMD3(1, 1, 1) : SIMD3(0.8, 0.8, 0.8)
        let a = min(max(c.w, 0), 1)
        return SIMD4(SIMD3(c.x, c.y, c.z) + ck * (1 - a), 1)
    }
}
