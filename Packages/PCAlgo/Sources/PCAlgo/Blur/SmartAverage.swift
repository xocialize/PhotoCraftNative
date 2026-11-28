// Port of photocraft-algo (crates/algo/src/blur2.rs: smart_blur) and photocraft-engine's Average
// (crates/engine/src/extra_cmds.rs: average), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Metal
import PCFoundation

/// Smart Blur sampling quality.
public enum BlurQuality: String, Codable, Sendable, Hashable, CaseIterable { case low, medium, high }

/// Smart Blur output.
public enum SmartBlurMode: String, Codable, Sendable, Hashable, CaseIterable { case normal, edgeOnly, overlayEdge }

/// Filter › Blur › Smart Blur: averages only neighbours within `threshold` levels of the centre
/// pixel (edges stay crisp); Edge Only / Overlay Edge draw edges (a 4-neighbour differing by more
/// than the threshold) in white. Radius 0.1–100 px, threshold 0.1–100 levels.
public struct SmartBlur: Filter, Hashable {
    public var radius: Float
    public var threshold: Float
    public var quality: BlurQuality
    public var mode: SmartBlurMode
    public init(radius: Float = 3, threshold: Float = 25, quality: BlurQuality = .medium, mode: SmartBlurMode = .normal) {
        self.radius = radius; self.threshold = threshold; self.quality = quality; self.mode = mode
    }
    public var label: String { "Smart Blur" }
    /// The kernel clamps the radius to 100 px: the source window is sized by what it uses (photocraft #8946).
    public func halo(bounds: PixelRect) -> Halo { .reach(min(radius, 100)) }

    /// The threshold test spans every colour channel: one GPU plane must hold them all.
    public var gpuChannels: GPUChannels { .joint }
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool { ctx.colorChannels(channels) <= (ctx.alpha ? 3 : 4) }

    var offsets: [(Int32, Int32)] {
        let r = clampf(radius, 0.1, 100)
        let ri = Int32(r.rounded(.up))
        let target: Int32 = quality == .low ? 4 : quality == .medium ? 7 : 12
        let stride = max((ri + target - 1) / target, 1)
        var offs: [(Int32, Int32)] = []
        for dy in Swift.stride(from: -ri, through: ri, by: Int(stride)) {
            for dx in Swift.stride(from: -ri, through: ri, by: Int(stride)) where Float(dx * dx + dy * dy) <= r * r + 0.5 {
                offs.append((dx, dy))
            }
        }
        return offs
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels, cc = ctx.colorChannels(n)
        let t = clampf(threshold, 0.1, 100) / 255
        let offs = offsets
        let white = ctx.native(SIMD4(1, 1, 1, 1), channels: n), black = ctx.native(SIMD4(0, 0, 0, 1), channels: n)
        var res = src.crop(out)
        let mode = self.mode
        res.data.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelChunks(out.height, minChunk: 2) { rows in
                var q = [Float](repeating: 0, count: n), acc = [Float](repeating: 0, count: n), me = [Float](repeating: 0, count: n)
                for oy in rows {
                    for ox in 0..<out.width {
                        let x = out.x0 + Int32(ox), y = out.y0 + Int32(oy)
                        let b = (oy * out.width + ox) * n
                        for c in 0..<n { me[c] = rs.value[b + c] }
                        func differs() -> Bool { for c in 0..<cc where abs(q[c] - me[c]) > t { return true }; return false }
                        if mode != .normal {
                            var edge = false
                            for (dx, dy) in [(Int32(1), Int32(0)), (0, 1), (-1, 0), (0, -1)] {
                                for c in 0..<n { q[c] = src.get(x + dx, y + dy, c) }
                                if differs() { edge = true; break }
                            }
                            let a: Float = ctx.alpha ? me[n - 1] : 1
                            if edge { for c in 0..<cc { rs.value[b + c] = white[c] } }
                            else if mode == .edgeOnly { for c in 0..<cc { rs.value[b + c] = black[c] } }
                            if ctx.alpha { rs.value[b + n - 1] = a }
                            continue
                        }
                        for c in 0..<n { acc[c] = 0 }
                        var wsum: Float = 0
                        for (dx, dy) in offs {
                            for c in 0..<n { q[c] = src.get(x + dx, y + dy, c) }
                            if differs() { continue }
                            let a: Float = ctx.alpha ? q[n - 1] : 1
                            for c in 0..<n { acc[c] += ctx.alpha && c < n - 1 ? q[c] * a : q[c] }
                            wsum += 1
                        }
                        if wsum > 0 {
                            for c in 0..<n { acc[c] /= wsum }
                            FxUtil.unpremulPx(&acc, ctx.alpha)
                            for c in 0..<n { rs.value[b + c] = acc[c] }
                        }
                    }
                }
            }
        }
        return res
    }

    struct Offset: BitwiseCopyable { var dx: Int32; var dy: Int32 }
    struct Params: BitwiseCopyable {
        var white: SIMD4<Float>
        var black: SIMD4<Float>
        var t: Float
        var mode: UInt32
        var count: Int32
        var pad: Int32 = 0
    }
    public func encodeGPU(_ pass: GPUPass) throws {
        let n = pass.ctx.alpha ? pass.planeChannels.count + 1 : pass.planeChannels.count
        let wn = pass.ctx.native(SIMD4(1, 1, 1, 1), channels: max(n, 1)), bn = pass.ctx.native(SIMD4(0, 0, 0, 1), channels: max(n, 1))
        var w = SIMD4<Float>(repeating: 0), b = SIMD4<Float>(repeating: 0)
        for k in 0..<pass.planeChannels.count { w[k] = wn[k]; b[k] = bn[k] }
        let offs = offsets.map { Offset(dx: $0.0, dy: $0.1) }
        let p = Params(white: w, black: b, t: clampf(threshold, 0.1, 100) / 255, mode: mode == .normal ? 0 : mode == .edgeOnly ? 1 : 2,
                       count: Int32(offs.count))
        try pass.dispatchOut("pca_smart_blur", params: p, buffers: [try pass.buffer(offs)])
    }
}

/// Filter › Blur › Average: every pixel of the reference bounds becomes their alpha-weighted mean
/// colour (and mean alpha), computed in straight sRGB for models other than Gray and RGB, as
/// photocraft's engine does. (photocraft also weights by the selection coverage; here the
/// coverage only mixes the result, per the engine's general selection contract.)
public struct AverageBlur: Filter, Hashable {
    public init() {}
    public var label: String { "Average" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }
    public var gpuChannels: GPUChannels { .joint }

    /// (Σ colour·α, Σ α, count) over the bounds, in the native model (Gray/RGB) or via sRGB.
    func average(_ src: FloatImage, _ ctx: FilterContext) -> [Float]? {
        let n = src.channels, cc = ctx.colorChannels(n)
        let area = ctx.bounds.intersect(src.rect)
        let viaRGB = !(ctx.mode.isGrayLike || ctx.mode.isRGBLike)
        let m = viaRGB ? 3 : cc
        var sum = [Double](repeating: 0, count: m)
        var wsum = 0.0, asum = 0.0, count = 0.0
        if !area.isEmpty {
            for y in area.y0..<area.y1 {
                for x in area.x0..<area.x1 {
                    let i = src.index(x: x, y: y)
                    let a: Float = ctx.alpha ? src.data[i + n - 1] : 1
                    if viaRGB {
                        let c = src.data.withUnsafeBufferPointer { ctx.rgba(UnsafeBufferPointer(rebasing: $0[i..<(i + n)])) }
                        for k in 0..<3 { sum[k] += Double(c[k]) * Double(a) }
                    } else {
                        for k in 0..<cc { sum[k] += Double(src.data[i + k]) * Double(a) }
                    }
                    wsum += Double(a); asum += Double(a); count += 1
                }
            }
        }
        if wsum <= 0 { return nil }
        var avg = (0..<m).map { Float(sum[$0] / wsum) }
        let alpha = Float(asum / max(count, 1e-9))
        if viaRGB {
            avg = ctx.native(SIMD4(avg[0], avg[1], avg[2], alpha), channels: n)
            return avg
        }
        if ctx.alpha { avg.append(alpha) }
        return avg
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        guard let avg = average(src, ctx) else { return src.crop(out) }
        var res = FloatImage(rect: out, channels: src.channels)
        for i in 0..<out.area { for c in 0..<src.channels { res.data[i * src.channels + c] = avg[c] } }
        return res
    }

    struct Params: BitwiseCopyable {
        var areaOrigin: SIMD2<Int32>
        var areaSize: SIMD2<Int32>
        var groups: Int32
        var pad0: Int32 = 0
        var pad1: Int32 = 0
        var pad2: Int32 = 0
    }
    public func encodeGPU(_ pass: GPUPass) throws {
        let area = pass.ctx.bounds.intersect(pass.srcRect)
        let groups = max(1, min((area.area + 4095) / 4096, 4096))
        let p = Params(areaOrigin: SIMD2(area.x0, area.y0), areaSize: SIMD2(Int32(area.width), Int32(area.height)), groups: Int32(groups))
        // Per-group partial sums (Σ colour·α, Σ α) then one group folds them and the fill writes the mean.
        let partial = try pass.scratchBuffer(length: groups * 32)
        let total = try pass.scratchBuffer(length: 32)
        try pass.dispatch("pca_average_partial", params: p, textures: [pass.src], buffers: [partial], width: groups * 256, height: 1,
                          threadgroup: (256, 1), threadgroupMemory: [256 * 32])
        try pass.dispatch("pca_average_total", params: p, textures: [], buffers: [partial, total], width: 256, height: 1,
                          threadgroup: (256, 1), threadgroupMemory: [256 * 32])
        try pass.dispatchOut("pca_average_fill", params: p, buffers: [total])
    }
}
