// Filter adjustment layers (AB-T-0258) on the GPU: the Metal side of Filters.swift. New; no
// photocraft counterpart.
//
// Grain and Add Noise run on a cell's accumulator like an adjustment (`pcr_filter_grain`,
// `pcr_filter_noise`). A blur's backdrop is rendered before the cells: its program (the plan up to
// the layer) composited over the render region plus the blur's reach within the canvas by a nested
// render, then premultiplied, blurred over the whole region at once (`pcr_blur_h` / `pcr_blur_v`, or
// `pcr_blur_motion`) and read by each cell as a leaf.

import Foundation
import Metal
import PCDocument
import PCFoundation

/// A backdrop filter ready for the cells: the backdrop over `area` (when the op pushes it) and the
/// filtered result over `region` (both straight RGBA, texel (0, 0) at the rect's corner).
struct GPUBackdrop {
    let area: PixelRect
    let backdrop: (any MTLTexture)?
    let region: PixelRect
    let filtered: any MTLTexture
}

enum FilterGPU {
    /// Grain's or Add Noise's uniforms in `op`; returns the kernel's name.
    static func encode(_ f: FilterSpec, _ ctx: RenderContext, _ op: inout PCROp) -> String {
        let hdr: Float = ctx.depth == .f32 ? 1 : 0
        switch f.filter {
        case .grain(let g):
            let p = FilterMath.Grain(g, scale: f.scale)
            op.p0 = SIMD4(p.strength, p.roughness, p.size, p.detailSize)
            op.p1 = SIMD4(p.unitsPerPixel, hdr, 0, 0)
            op.aux = SIMD2(Int32(bitPattern: p.seed), Int32(bitPattern: p.fineSeed))
            return "pcr_filter_grain"
        case .addNoise(let n):
            let p = FilterMath.Noise(n, scale: f.scale)
            op.p0 = SIMD4(p.spread, p.gaussian ? 1 : 0, p.monochromatic ? 1 : 0, hdr)
            op.aux = SIMD2(Int32(bitPattern: p.seed), 0)
            return "pcr_filter_noise"
        case .gaussianBlur, .motionBlur:
            // `unsupportedReason` keeps a blur of a buffer on its own off the GPU.
            preconditionFailure("FilterGPU.encode: \(f.filter.label) is not a pointwise filter")
        }
    }
}

extension MetalCompositor {
    /// `b`'s program composited over the backdrop area of `region` in accumulators of `format`, and
    /// the blur of it over `region`. The nested render waits for its cells; the blur is committed
    /// behind it, so the queue finishes it before any later cell reads it.
    func gpuBackdrop(_ b: BackdropFilter, ctx: RenderContext, region: PixelRect, source: any RenderSource,
                     format: MTLPixelFormat) throws -> GPUBackdrop {
        let area = FilterMath.backdropArea(region, reach: FilterMath.reach(b.spec), canvas: ctx.canvas)
        func texture(_ w: Int, _ h: Int) throws -> any MTLTexture {
            guard let t = context.makeTexture(width: max(w, 1), height: max(h, 1), pixelFormat: .rgba32Float,
                                              usage: [.shaderRead, .shaderWrite], storage: .private) else {
                throw MetalCompositorError.gpu("backdrop texture \(w)×\(h)")
            }
            return t
        }
        let back = try texture(area.width, area.height)
        let program = RenderPlan(context: ctx, ops: b.program)
        do { try program.validate() } catch { throw MetalCompositorError.gpu(error.description) }
        _ = try renderLocked(program, region: area, source: source, out: back, format: format) { _ in }

        guard let cb = context.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
            throw MetalCompositorError.gpu("backdrop filter encoder")
        }
        cb.label = "PCRender \(b.spec.filter.label)"
        func dispatch(_ name: String, _ op: PCROp, _ grid: (Int, Int), _ input: any MTLTexture, _ output: any MTLTexture,
                      weights: (any MTLBuffer)? = nil) throws {
            var o = op
            o.size = SIMD2(Int32(grid.0), Int32(grid.1))
            kernels.dispatch(enc, try kernels.pipeline(name), op: o, grid: grid, textures: [Slot.a: input, Slot.out: output],
                             buffers: weights.map { [1: $0] } ?? [:])
        }
        // Premultiplied, nothing past the canvas.
        let pm = try texture(area.width, area.height)
        var op = PCROp()
        op.aux = SIMD2(area.x0, area.y0)
        let c = ctx.canvas
        op.p0 = SIMD4(Float(c.x0), Float(c.y0), Float(c.x1), Float(c.y1))
        try dispatch("pcr_blur_premultiply", op, (area.width, area.height), back, pm)
        let filtered = try texture(region.width, region.height)
        switch b.spec.filter {
        case .gaussianBlur(let g):
            let w = FilterMath.gaussianWeights(sigma: g.radius * b.spec.scale)
            let r = Int32((w.count - 1) / 2)
            guard let wb = kernels.buffer(w) else { throw MetalCompositorError.gpu("blur weights") }
            // Rows of the horizontal pass: the region's ± R, where the backdrop has any.
            let hy0 = max(region.y0 - r, area.y0), hy1 = min(region.y1 + r, area.y1)
            let rows = max(0, Int(hy1 - hy0))
            let h = try texture(region.width, rows)
            var oh = PCROp()
            oh.offset = SIMD2(region.x0 - area.x0, hy0 - area.y0)
            oh.aux = SIMD2(r, Int32(w.count))
            oh.p0 = SIMD4(Float(area.width), Float(area.height), 0, 0)
            if rows > 0 { try dispatch("pcr_blur_h", oh, (region.width, rows), pm, h, weights: wb) }
            var ov = PCROp()
            ov.offset = SIMD2(0, region.y0 - hy0)
            ov.aux = SIMD2(r, Int32(w.count))
            ov.p0 = SIMD4(Float(region.width), Float(rows), 0, 0)
            try dispatch("pcr_blur_v", ov, (region.width, region.height), h, filtered, weights: wb)
        case .motionBlur(let m):
            let taps = FilterMath.motionTaps(m, scale: b.spec.scale)
            guard let tb = kernels.buffer(taps) else { throw MetalCompositorError.gpu("blur taps") }
            var om = PCROp()
            om.offset = SIMD2(region.x0 - area.x0, region.y0 - area.y0)
            om.aux = SIMD2(0, Int32(taps.count))
            om.p0 = SIMD4(Float(area.width), Float(area.height), 0, 0)
            try dispatch("pcr_blur_motion", om, (region.width, region.height), pm, filtered, weights: tb)
        case .grain, .addNoise:
            // `unsupportedReason` keeps a pointwise backdrop filter (never planned) on the CPU.
            throw MetalCompositorError.unsupported("\(b.spec.filter.label) of a backdrop")
        }
        enc.endEncoding()
        cb.commit()
        return GPUBackdrop(area: area, backdrop: b.pushesBackdrop ? back : nil, region: region, filtered: filtered)
    }
}
