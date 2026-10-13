// Port of photocraft-algo (crates/algo/src/lib.rs: apply, apply_in, output_area, mix_selection), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The runner: one filter over a FloatImage (CPU reference or Metal), mixed with the original by a
// selection coverage, plus the Surface-level convenience that reads the halo'd region (repeating
// the canvas edge as Photoshop does), runs, mixes and writes back.

import Foundation
import Metal
import PCFoundation

/// Timing of one engine run.
public struct FilterRunStats: Sendable {
    /// Wall-clock seconds for the whole call (upload, kernels, readback, mixing).
    public var wallSeconds: Double
    /// GPU execution seconds of the command buffer (0 on the CPU).
    public var gpuSeconds: Double
    public var backend: Backend
}

public enum FilterEngine {
    /// Runs `filter` for `output` (default: the source rectangle) from `src`, which should cover
    /// the output grown by the filter's halo (samples outside `src` read as 0). `coverage` is a
    /// per-pixel selection coverage over `output` (row-major); the result is mixed with the
    /// original by it, premultiplied where the filter changed alpha (photocraft `mix_selection`).
    public static func apply<F: Filter>(_ filter: F, to src: FloatImage, output: PixelRect? = nil, context: FilterContext? = nil,
                                        coverage: [Float]? = nil, on backend: Backend = .auto) throws -> FloatImage {
        try run(filter, src: src, output: output, context: context, coverage: coverage, backend: backend).0
    }

    /// `apply` that also reports timings.
    public static func applyMeasured<F: Filter>(_ filter: F, to src: FloatImage, output: PixelRect? = nil, context: FilterContext? = nil,
                                                coverage: [Float]? = nil, on backend: Backend = .auto) throws -> (FloatImage, FilterRunStats) {
        try run(filter, src: src, output: output, context: context, coverage: coverage, backend: backend)
    }

    /// Whether `filter` would run on the GPU for this input under `.auto` (directly, or through an
    /// sRGB round trip for `rgbaEquivalent` filters on CMYK/Lab documents).
    public static func runsOnGPU<F: Filter>(_ filter: F, channels: Int, context: FilterContext) -> Bool {
        AlgoGPU.isAvailable && filter.gpuChannels != .none
            && (filter.supportsGPU(context, channels: channels) || rgbaRoundTrip(filter, channels: channels, context: context))
    }

    /// Whether a CMYK/Lab document can run as its sRGB conversion (see `Filter.rgbaEquivalent`).
    static func rgbaRoundTrip<F: Filter>(_ filter: F, channels: Int, context ctx: FilterContext) -> Bool {
        guard filter.rgbaEquivalent, !(ctx.mode.isGrayLike || ctx.mode.isRGBLike), channels == ctx.mode.colorChannels + (ctx.alpha ? 1 : 0) else { return false }
        let rgbCtx = FilterContext(bounds: ctx.bounds, mode: .rgb, alpha: ctx.alpha, sample: ctx.sample)
        return filter.supportsGPU(rgbCtx, channels: ctx.alpha ? 4 : 3)
    }

    /// The straight sRGB(A) conversion of `src` (`ctx.rgba` per pixel), as an RGB(A) image.
    static func toRGBA(_ src: FloatImage, _ ctx: FilterContext) -> (FloatImage, FilterContext) {
        let n = src.channels, m = ctx.alpha ? 4 : 3
        var out = FloatImage(rect: src.rect, channels: m)
        src.data.withUnsafeBufferPointer { sp in
            out.data.withUnsafeMutableBufferPointer { ob in
                let os = UnsafeSendable(ob)
                parallelChunks(src.rect.area, minChunk: 4096) { r in
                    for i in r {
                        let c = ctx.rgba(UnsafeBufferPointer(rebasing: sp[(i * n)..<(i * n + n)]))
                        for k in 0..<m { os.value[i * m + k] = c[k] }
                    }
                }
            }
        }
        return (out, FilterContext(bounds: ctx.bounds, mode: .rgb, alpha: ctx.alpha, sample: ctx.sample))
    }

    /// Writes an RGB(A) result back into the document's model (`ctx.setRGBA` per pixel).
    static func fromRGBA(_ rgb: FloatImage, original: FloatImage, _ ctx: FilterContext) -> FloatImage {
        var res = original
        let n = original.channels, m = rgb.channels
        rgb.data.withUnsafeBufferPointer { rp in
            res.data.withUnsafeMutableBufferPointer { ob in
                let os = UnsafeSendable(ob)
                parallelChunks(original.rect.area, minChunk: 4096) { r in
                    for i in r {
                        let c = SIMD4(rp[i * m], rp[i * m + 1], rp[i * m + 2], m == 4 ? rp[i * m + 3] : 1)
                        ctx.setRGBA(UnsafeMutableBufferPointer(rebasing: os.value[(i * n)..<(i * n + n)]), c)
                    }
                }
            }
        }
        return res
    }

    static func run<F: Filter>(_ filter: F, src: FloatImage, output: PixelRect?, context: FilterContext?, coverage: [Float]?,
                               backend: Backend) throws -> (FloatImage, FilterRunStats) {
        let out = output ?? src.rect
        let ctx = context ?? FilterContext.inferred(channels: src.channels, bounds: src.rect)
        // The contract: samples the filter reads outside `src` are 0. Filters are written for a
        // source that covers what they read (the Surface runner always passes one); a caller's
        // narrower source is padded with transparency so every filter and both backends see the
        // same thing (QA: several filters indexed past an uncovered source).
        let need: PixelRect
        switch filter.halo(bounds: ctx.bounds) {
        case .radius(let r): need = out.isEmpty ? .empty : out.outset(by: r)
        case .bounds: need = out.isEmpty ? .empty : ctx.bounds.union(out)
        }
        let src = need.isEmpty || src.rect.contains(need) ? src : src.crop(src.rect.union(need))
        if let cov = coverage, cov.count != out.area {
            throw FilterError.invalidInput("coverage has \(cov.count) values for \(out.area) pixels")
        }
        if ctx.alpha && src.channels < 2 { throw FilterError.invalidInput("alpha needs at least 2 channels") }
        let viaRGB = !filter.supportsGPU(ctx, channels: src.channels) && rgbaRoundTrip(filter, channels: src.channels, context: ctx)
        let useGPU: Bool
        switch backend {
        case .cpu: useGPU = false
        case .gpu:
            guard filter.gpuChannels != .none, filter.supportsGPU(ctx, channels: src.channels) || viaRGB else {
                throw FilterError.gpuUnsupported("\(filter.label) for \(ctx.mode) with \(src.channels) channels")
            }
            useGPU = true
        case .auto: useGPU = runsOnGPU(filter, channels: src.channels, context: ctx)
        }
        let t0 = Date()
        var gpuSeconds = 0.0
        var res: FloatImage
        var ranGPU = useGPU
        if useGPU {
            do {
                if viaRGB {
                    let (rgbSrc, rgbCtx) = toRGBA(src, ctx)
                    let (rgbRes, t) = try runGPU(filter, src: rgbSrc, out: out, ctx: rgbCtx)
                    res = fromRGBA(rgbRes, original: src.crop(out), ctx)
                    gpuSeconds = t
                } else {
                    (res, gpuSeconds) = try runGPU(filter, src: src, out: out, ctx: ctx)
                }
            } catch FilterError.gpuUnsupported where backend == .auto {
                // A filter may only find out while encoding (data-dependent paths, size limits).
                res = filter.cpu(src, out: out, ctx: ctx)
                ranGPU = false
            }
        } else {
            res = filter.cpu(src, out: out, ctx: ctx)
        }
        precondition(res.rect == out && res.channels == src.channels, "\(filter.label): result shape mismatch")
        if let cov = coverage { res = mixSelection(original: src.crop(out), filtered: res, coverage: cov, alpha: ctx.alpha) }
        let stats = FilterRunStats(wallSeconds: Date().timeIntervalSince(t0), gpuSeconds: gpuSeconds, backend: ranGPU ? .gpu : .cpu)
        return (res, stats)
    }

    /// Largest texture edge the GPU path handles in one piece.
    public static let maxGPUSize = 16384

    static func runGPU<F: Filter>(_ filter: F, src: FloatImage, out: PixelRect, ctx: FilterContext) throws -> (FloatImage, Double) {
        let gpu = try AlgoGPU.shared()
        if out.isEmpty { return (FloatImage(rect: out, channels: src.channels), 0) }
        if max(src.width, src.height, out.width, out.height) > maxGPUSize {
            throw FilterError.gpuUnsupported("images larger than \(maxGPUSize) px (use the Surface-level apply, which tiles)")
        }
        let layout = PlaneLayout(channels: src.channels, alpha: ctx.alpha)
        let srcBytes = max(src.rect.area, 1) * 16, outBytes = out.area * 16
        var readbacks: [any MTLBuffer] = [], uploads: [any MTLBuffer] = []
        var textures: [any MTLTexture] = [], passes: [GPUPass] = []
        var gpuTime = 0.0
        var lastCB: (any MTLCommandBuffer)?
        try gpu.metal.run(label: filter.label) { cb in
            for (p, cols) in layout.planes.enumerated() {
                let up = try gpu.stagingBuffer(length: srcBytes), down = try gpu.stagingBuffer(length: outBytes)
                uploads.append(up)
                if !src.rect.isEmpty { layout.pack(src, plane: p, into: up.contents().assumingMemoryBound(to: Float.self)) }
                else { memset(up.contents(), 0, srcBytes) }
                let sw = max(src.width, 1), sh = max(src.height, 1)
                let srcTex = try gpu.cachedTexture(width: sw, height: sh, exact: true)
                let dstTex = try gpu.cachedTexture(width: out.width, height: out.height, exact: true)
                textures += [srcTex, dstTex]
                guard let blit = cb.makeBlitCommandEncoder() else { throw FilterError.gpuUnavailable("blit") }
                blit.copy(from: up, sourceOffset: 0, sourceBytesPerRow: sw * 16, sourceBytesPerImage: sw * sh * 16,
                          sourceSize: MTLSize(width: sw, height: sh, depth: 1), to: srcTex, destinationSlice: 0,
                          destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
                let frame = PCAFrame(
                    srcOrigin: SIMD2(src.rect.x0, src.rect.y0), srcSize: SIMD2(Int32(src.width), Int32(src.height)),
                    outOrigin: SIMD2(out.x0, out.y0), outSize: SIMD2(Int32(out.width), Int32(out.height)),
                    boundsOrigin: SIMD2(ctx.bounds.x0, ctx.bounds.y0), boundsSize: SIMD2(Int32(ctx.bounds.width), Int32(ctx.bounds.height)),
                    alpha: ctx.alpha ? 1 : 0, mode: ctx.gpuModeCode, ncomp: UInt32(cols.count), plane: UInt32(p),
                    colorChannels: UInt32(ctx.colorChannels(src.channels)), firstChannel: UInt32(cols.first ?? 0))
                let pass = GPUPass(gpu: gpu, commandBuffer: cb, src: srcTex, dst: dstTex, frame: frame, ctx: ctx,
                                   srcRect: src.rect, out: out, plane: p, planeChannels: cols)
                try filter.encodeGPU(pass)
                passes.append(pass)
                guard let back = cb.makeBlitCommandEncoder() else { throw FilterError.gpuUnavailable("blit") }
                back.copy(from: dstTex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: out.width, height: out.height, depth: 1), to: down,
                          destinationOffset: 0, destinationBytesPerRow: out.width * 16, destinationBytesPerImage: outBytes)
                back.endEncoding()
                readbacks.append(down)
            }
            lastCB = cb
        }
        if let cb = lastCB { gpuTime = cb.gpuEndTime - cb.gpuStartTime }
        // Every channel is written by the planes (alpha by plane 0), so the result starts uninitialised.
        let count = out.area * src.channels
        var result = FloatImage(rect: out, channels: src.channels,
                                data: [Float](unsafeUninitializedCapacity: count) { _, n in n = count })
        for (p, b) in readbacks.enumerated() {
            layout.unpack(b.contents().assumingMemoryBound(to: Float.self), plane: p, into: &result)
        }
        for b in uploads + readbacks { gpu.returnStaging(b) }
        gpu.releaseTextures(textures + passes.flatMap(\.allocated))
        return (result, gpuTime)
    }

    /// Mixes `filtered` back toward `original` by the selection coverage (clamped to 0…1). Where
    /// the filter changed alpha, colour is interpolated premultiplied, so hidden colours don't leak
    /// into feathered edges (photocraft `mix_selection`; `FloatImage.mixed` is the straight lerp).
    public static func mixSelection(original: FloatImage, filtered: FloatImage, coverage: [Float], alpha: Bool) -> FloatImage {
        var res = filtered
        let n = original.channels
        original.data.withUnsafeBufferPointer { o in
            res.data.withUnsafeMutableBufferPointer { px in
                for i in 0..<original.rect.area {
                    let k = min(max(coverage[i], 0), 1)
                    let b = i * n
                    if k >= 1 { continue }
                    if k <= 0 { for c in 0..<n { px[b + c] = o[b + c] }; continue }
                    if alpha {
                        let a = n - 1
                        let oa = o[b + a], fa = px[b + a]
                        if oa != fa {
                            let ma = oa + (fa - oa) * k
                            let ow = oa * (1 - k), fw = fa * k
                            for c in 0..<a { px[b + c] = ma > 0 ? (o[b + c] * ow + px[b + c] * fw) / ma : 0 }
                            px[b + a] = ma
                            continue
                        }
                    }
                    for c in 0..<n { px[b + c] = o[b + c] + (px[b + c] - o[b + c]) * k }
                }
            }
        }
        return res
    }

    // MARK: Surface level

    /// The area a filter writes for a layer whose pixels cover `content` (photocraft
    /// `output_area`): global filters write the bounds, others the content grown by the halo;
    /// clipped to the selection's bounds when there is one.
    public static func outputArea<F: Filter>(_ filter: F, content: PixelRect, bounds: PixelRect, selectionBounds: PixelRect? = nil) -> PixelRect {
        var area: PixelRect
        switch filter.halo(bounds: bounds) {
        case .bounds: area = bounds
        case .radius(let r): area = content.isEmpty ? .empty : content.outset(by: r)
        }
        if let sb = selectionBounds { area = area.intersect(sb) }
        return area
    }

    /// Applies `filter` to `area` of `surface` in place (photocraft `apply` / `apply_in`).
    /// `bounds` is the reference area (selection bounds, else the canvas). With `extent` (the
    /// canvas plus any off-canvas pixels), neighbourhood filters repeat its edge pixels instead of
    /// reading transparency beyond it, and the output is clipped to it. `selection` channel 0 is
    /// the coverage. Work proceeds in tiles of `tile` pixels; results don't depend on the tiling.
    public static func apply<F: Filter>(_ filter: F, to surface: inout Surface, area: PixelRect, bounds: PixelRect,
                                        selection: Surface? = nil, extent: PixelRect? = nil, on backend: Backend = .auto,
                                        tile: Int = 2048) throws {
        let area = extent.map { area.intersect($0) } ?? area
        if area.isEmpty { return }
        let ctx = FilterContext(bounds: bounds, format: surface.format)
        let halo = filter.halo(bounds: bounds)
        let shared: FloatImage? = halo == .bounds ? FloatImage(surface: surface, rect: bounds.union(area)) : nil
        // On the CPU, running-sum box blurs filter the whole area at once, as photocraft's
        // `apply_box_blur` does (bit-identical whatever the tiling). The GPU sums in float either
        // way, so it keeps to tiles (bounded texture memory).
        let gpu: Bool
        switch backend {
        case .cpu: gpu = false
        case .gpu: gpu = true
        case .auto: gpu = runsOnGPU(filter, channels: surface.channels, context: ctx)
        }
        // Global filters read the whole bounds anyway: one piece (their per-image statistics —
        // means, histograms — are then computed once), within the GPU's texture limit.
        let global = halo == .bounds && max(area.width, area.height) <= maxGPUSize
        let whole = (filter.processesWholeArea && !gpu) || global
        let t = whole ? Int32(max(area.width, area.height)) : Int32(max(tile, 1))
        var tiles: [PixelRect] = []
        var y = area.y0
        while y < area.y1 {
            var x = area.x0
            while x < area.x1 {
                tiles.append(PixelRect(x0: x, y0: y, x1: min(x + t, area.x1), y1: min(y + t, area.y1)))
                x += t
            }
            y += t
        }
        var results: [(PixelRect, FloatImage)] = []
        for r in tiles {
            let src: FloatImage
            if let s = shared { src = s }
            else if case .radius(let h) = halo {
                let grown = r.outset(by: h)
                src = extent.map { FloatImage(surface: surface, rect: grown, clampedTo: $0) } ?? FloatImage(surface: surface, rect: grown)
            } else { src = FloatImage(surface: surface, rect: r) }
            let cov: [Float]? = selection.map { sel in
                let raw = sel.readRegion(r)
                let sc = sel.channels
                return (0..<r.area).map { raw[$0 * sc] }
            }
            let res = try apply(filter, to: src, output: r, context: ctx, coverage: cov, on: backend)
            results.append((r, res))
        }
        for (r, res) in results { surface.writeRegion(r, res.data) }
        surface.prune()
    }
}
