// Port of photocraft-algo (crates/algo/src/lib.rs: the filter kernel contract), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// GPU-resident filtering: encode a filter into a caller's command buffer between textures the
// caller owns (a compositor's layer cache, a preview chain), with no upload or readback.

import Metal
import PCFoundation

extension FilterEngine {
    /// Encodes `filter` into `commandBuffer`: reads `source` (an `rgba32Float` texture in PCAlgo's
    /// plane layout covering `sourceRect`: up to three colour channels + alpha in `.w`, or four
    /// colour channels without alpha) and writes `destination` (same layout, covering `output`).
    /// `planeChannels` are the image channels the plane carries (default: all colour channels of a
    /// one-plane image). Intermediates return to PCAlgo's cache when the command buffer completes.
    /// Throws when the filter has no Metal path for this input.
    public static func encode<F: Filter>(_ filter: F, commandBuffer: any MTLCommandBuffer, source: any MTLTexture, sourceRect: PixelRect,
                                         destination: any MTLTexture, output: PixelRect, context ctx: FilterContext,
                                         channels: Int, plane: Int = 0, planeChannels: [Int]? = nil) throws {
        guard filter.gpuChannels != .none, filter.supportsGPU(ctx, channels: channels) else {
            throw FilterError.gpuUnsupported("\(filter.label) for \(ctx.mode) with \(channels) channels")
        }
        let gpu = try AlgoGPU.shared()
        let layout = PlaneLayout(channels: channels, alpha: ctx.alpha)
        let cols = planeChannels ?? layout.planes[min(plane, layout.planes.count - 1)]
        let frame = PCAFrame(
            srcOrigin: SIMD2(sourceRect.x0, sourceRect.y0), srcSize: SIMD2(Int32(sourceRect.width), Int32(sourceRect.height)),
            outOrigin: SIMD2(output.x0, output.y0), outSize: SIMD2(Int32(output.width), Int32(output.height)),
            boundsOrigin: SIMD2(ctx.bounds.x0, ctx.bounds.y0), boundsSize: SIMD2(Int32(ctx.bounds.width), Int32(ctx.bounds.height)),
            alpha: ctx.alpha ? 1 : 0, mode: ctx.gpuModeCode, ncomp: UInt32(cols.count), plane: UInt32(plane),
            colorChannels: UInt32(ctx.colorChannels(channels)), firstChannel: UInt32(cols.first ?? 0))
        let pass = GPUPass(gpu: gpu, commandBuffer: commandBuffer, src: source, dst: destination, frame: frame, ctx: ctx,
                           srcRect: sourceRect, out: output, plane: plane, planeChannels: cols)
        try filter.encodeGPU(pass)
        let allocated = UnsafeSendable(pass.allocated)
        commandBuffer.addCompletedHandler { _ in gpu.releaseTextures(allocated.value) }
    }
}
