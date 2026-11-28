// Port of photocraft-algo (crates/algo/src/other.rs, other2.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Other: Minimum and Maximum (square or round), Offset, Custom (5×5 convolution).

import Foundation
import Metal
import MetalPerformanceShaders
import PCFoundation

/// Minimum / Maximum › Preserve: the shape the filter grows or shrinks by.
public enum Preserve: String, Codable, Sendable, Hashable, CaseIterable {
    /// A square of `2·radius + 1` pixels (keeps corners square).
    case squareness
    /// A disc of `radius` pixels (rounds corners off evenly).
    case roundness
}

enum OtherKit {
    /// Square Minimum/Maximum through MPSImageAreaMin/Max (`PCALGO_NO_MPS` selects the MSL kernels).
    nonisolated(unsafe) static var useMPS = ProcessInfo.processInfo.environment["PCALGO_NO_MPS"] == nil

    /// `out[i]` = extreme of `v[i ..< i + k]` for every full window (van Herk / Gil-Werman) —
    /// photocraft `running_extreme`.
    static func runningExtreme(_ v: [Float], _ k: Int, _ isMax: Bool, _ out: inout [Float]) {
        out.removeAll(keepingCapacity: true)
        let n = v.count
        if k <= 1 { out.append(contentsOf: v); return }
        if n < k { return }
        @inline(__always) func pick(_ a: Float, _ b: Float) -> Float { isMax ? Float.maximum(a, b) : Float.minimum(a, b) }
        var pre = v, suf = v
        for i in 1..<n where i % k != 0 { pre[i] = pick(pre[i - 1], v[i]) }
        if n >= 2 { for i in stride(from: n - 2, through: 0, by: -1) where (i + 1) % k != 0 { suf[i] = pick(suf[i + 1], v[i]) } }
        for i in 0...(n - k) { out.append(pick(suf[i], pre[i + k - 1])) }
    }

    /// Minimum or Maximum over a square, separable (photocraft `min_max`).
    static func minMax(_ src: FloatImage, _ out: PixelRect, _ radius: Float, _ isMax: Bool) -> FloatImage {
        let n = src.channels
        let r = PCAMath.i32(PCAMath.pos(radius).rounded(.toNearestOrAwayFromZero))
        if r == 0 { return src.crop(out) }
        let k = Int(2 * r + 1)
        let win = PixelRect(x0: out.x0, y0: out.y0 - r, x1: out.x1, y1: out.y1 + r)
        let ww = win.width, wh = win.height
        var tmp = [Float](repeating: 0, count: ww * wh * n)
        tmp.withUnsafeMutableBufferPointer { tb in
            let t = UnsafeSendable(tb)
            parallelChunks(wh, minChunk: 4) { rows in
                var line: [Float] = [], ext: [Float] = []
                for wy in rows {
                    let y = win.y0 + Int32(wy)
                    let o = wy * ww * n
                    for c in 0..<n {
                        line.removeAll(keepingCapacity: true)
                        for x in (win.x0 - r)..<(win.x1 + r) { line.append(src.get(x, y, c)) }
                        runningExtreme(line, k, isMax, &ext)
                        for (x, v) in ext.enumerated() { t.value[o + x * n + c] = v }
                    }
                }
            }
        }
        let ow = out.width
        var res = FloatImage(rect: out, channels: n)
        tmp.withUnsafeBufferPointer { tb in
            res.data.withUnsafeMutableBufferPointer { rb in
                let rs = UnsafeSendable(rb)
                parallelChunks(ow, minChunk: 4) { cols in
                    var line: [Float] = [], ext: [Float] = []
                    for x in cols {
                        for c in 0..<n {
                            line.removeAll(keepingCapacity: true)
                            for y in 0..<wh { line.append(tb[(y * ww + x) * n + c]) }
                            runningExtreme(line, k, isMax, &ext)
                            for (y, v) in ext.enumerated() { rs.value[(y * ow + x) * n + c] = v }
                        }
                    }
                }
            }
        }
        return res
    }

    /// Half-width of the round window on row `dy` (photocraft `min_max_round`: the epsilon keeps
    /// exact squares, e.g. r 5, dy 3 → 4).
    static func roundHalfWidth(_ r: Float, _ dy: Int32) -> Int32 {
        Int32((max(r * r - Float(dy * dy), 0).squareRoot() + 1e-4).rounded(.down))
    }

    /// Minimum or Maximum over a disc, row by row of the disc with running extremes
    /// (photocraft `min_max_round`).
    static func minMaxRound(_ src: FloatImage, _ out: PixelRect, _ radius: Float, _ isMax: Bool) -> FloatImage {
        let n = src.channels
        let r = PCAMath.pos(radius)
        let ri = PCAMath.i32(r.rounded(.down))
        if ri == 0 { return src.crop(out) }
        let w = out.width
        var res = FloatImage(rect: out, channels: n)
        res.data = [Float](repeating: isMax ? -Float.greatestFiniteMagnitude : Float.greatestFiniteMagnitude, count: w * out.height * n)
        res.data.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelChunks(out.height, minChunk: 2) { rows in
                var row: [Float] = [], ext: [Float] = []
                for dy in -ri...ri {
                    let hw = roundHalfWidth(r, dy)
                    for oy in rows {
                        let y = out.y0 + Int32(oy)
                        let o = oy * w * n
                        for c in 0..<n {
                            row.removeAll(keepingCapacity: true)
                            for x in (out.x0 - hw)..<(out.x1 + hw) { row.append(src.get(x, y + dy, c)) }
                            runningExtreme(row, Int(2 * hw + 1), isMax, &ext)
                            for (x, v) in ext.enumerated() {
                                let i = o + x * n + c
                                rs.value[i] = isMax ? Float.maximum(rs.value[i], v) : Float.minimum(rs.value[i], v)
                            }
                        }
                    }
                }
            }
        }
        return res
    }

    struct MinMaxParams: BitwiseCopyable {
        var tmpOrigin: SIMD2<Int32>
        var tmpSize: SIMD2<Int32>
        var radius: Int32
        var isMax: UInt32
        var rows: Int32
        var pad0: Int32 = 0
    }
}

/// Filter › Other › Minimum: spreads dark (and transparent) areas over a square or disc.
public struct Minimum: Filter, Hashable {
    public var radius: Float
    public var preserve: Preserve
    public init(radius: Float = 1, preserve: Preserve = .squareness) { self.radius = radius; self.preserve = preserve }
    enum CodingKeys: String, CodingKey { case radius, preserve }
    /// photocraft `#[serde(default)] preserve` (older parameters: Squareness).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        radius = try c.decode(Float.self, forKey: .radius)
        preserve = try c.decodeIfPresent(Preserve.self, forKey: .preserve) ?? .squareness
    }
    public var label: String { "Minimum" }
    public func halo(bounds: PixelRect) -> Halo { .reach(radius) }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        preserve == .squareness ? OtherKit.minMax(src, out, radius, false) : OtherKit.minMaxRound(src, out, radius, false)
    }
    public func encodeGPU(_ pass: GPUPass) throws { try pass.encodeMinMax(radius: radius, isMax: false, preserve: preserve) }
}

/// Filter › Other › Maximum: spreads light areas over a square or disc.
public struct Maximum: Filter, Hashable {
    public var radius: Float
    public var preserve: Preserve
    public init(radius: Float = 1, preserve: Preserve = .squareness) { self.radius = radius; self.preserve = preserve }
    enum CodingKeys: String, CodingKey { case radius, preserve }
    /// photocraft `#[serde(default)] preserve` (older parameters: Squareness).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        radius = try c.decode(Float.self, forKey: .radius)
        preserve = try c.decodeIfPresent(Preserve.self, forKey: .preserve) ?? .squareness
    }
    public var label: String { "Maximum" }
    public func halo(bounds: PixelRect) -> Halo { .reach(radius) }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        preserve == .squareness ? OtherKit.minMax(src, out, radius, true) : OtherKit.minMaxRound(src, out, radius, true)
    }
    public func encodeGPU(_ pass: GPUPass) throws { try pass.encodeMinMax(radius: radius, isMax: true, preserve: preserve) }
}

extension GPUPass {
    func encodeMinMax(radius: Float, isMax: Bool, preserve: Preserve) throws {
        switch preserve {
        case .squareness:
            let r = PCAMath.i32(PCAMath.pos(radius).rounded(.toNearestOrAwayFromZero))
            if r == 0 { try dispatchOut("pca_copy", params: NoParams()); return }
            if OtherKit.useMPS {
                // Metal Performance Shaders' area extreme over the same (2r+1)² window; reads outside
                // the source are 0 (`.zero`), as photocraft's `Image::get`. Min/max are exact, so the
                // result is bit-identical to the reference.
                let side = Int(2 * r + 1)
                let k: MPSUnaryImageKernel = isMax ? MPSImageAreaMax(device: gpu.device, kernelWidth: side, kernelHeight: side)
                                                   : MPSImageAreaMin(device: gpu.device, kernelWidth: side, kernelHeight: side)
                k.edgeMode = .zero
                k.offset = MPSOffset(x: Int(out.x0 - srcRect.x0), y: Int(out.y0 - srcRect.y0), z: 0)
                k.clipRect = MTLRegionMake2D(0, 0, out.width, out.height)
                k.encode(commandBuffer: commandBuffer, sourceTexture: src, destinationTexture: dst)
                return
            }
            let tmpRect = PixelRect(x0: out.x0, y0: out.y0 - r, x1: out.x1, y1: out.y1 + r)
            let tmp = try texture(tmpRect)
            let p = OtherKit.MinMaxParams(tmpOrigin: SIMD2(tmpRect.x0, tmpRect.y0), tmpSize: SIMD2(Int32(tmpRect.width), Int32(tmpRect.height)),
                                          radius: r, isMax: isMax ? 1 : 0, rows: 0)
            try dispatch("pca_minmax_h", params: p, textures: [src, tmp], width: tmpRect.width, height: tmpRect.height)
            try dispatch("pca_minmax_v", params: p, textures: [tmp, dst], width: out.width, height: out.height)
        case .roundness:
            let r = PCAMath.pos(radius)
            let ri = PCAMath.i32(r.rounded(.down))
            if ri == 0 { try dispatchOut("pca_copy", params: NoParams()); return }
            let hws = (-ri...ri).map { OtherKit.roundHalfWidth(r, $0) }
            let p = OtherKit.MinMaxParams(tmpOrigin: .zero, tmpSize: .zero, radius: ri, isMax: isMax ? 1 : 0, rows: Int32(hws.count))
            try dispatchOut("pca_minmax_round", params: p, buffers: [try buffer(hws)])
        }
    }
}

/// Filter › Other › Offset: shifts the bounds' content by whole pixels; uncovered areas wrap,
/// repeat the edge or turn transparent.
public struct Offset: Filter, Hashable {
    public var horizontal: Int32
    public var vertical: Int32
    public var undefined: UndefinedAreas
    public init(horizontal: Int32, vertical: Int32, undefined: UndefinedAreas = .wrap) {
        self.horizontal = horizontal; self.vertical = vertical; self.undefined = undefined
    }
    public var label: String { "Offset" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels, undefined = undefined, b = ctx.bounds
        let (dx, dy) = (Int64(horizontal), Int64(vertical))
        var res = FloatImage(rect: out, channels: n)
        res.data.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelChunks(out.height, minChunk: 16) { rows in
                for oy in rows {
                    let sy = Self.source(Int64(out.y0) + Int64(oy), dy, b.y0, b.y1, undefined)
                    for x in out.x0..<out.x1 {
                        let i = (oy * out.width + Int(x - out.x0)) * n
                        if let sy, let sx = Self.source(Int64(x), dx, b.x0, b.x1, undefined) {
                            for c in 0..<n { rs.value[i + c] = src.get(sx, sy, c) }
                        }
                    }
                }
            }
        }
        return res
    }
    /// The source coordinate for `position − distance` inside `start..<end` under the edge policy,
    /// or nil where the result is transparent. Worked in 64 bits: the subtraction leaves Int32 for
    /// valid parameters, and saturating it first would change the wrapped pixel (photocraft #4738).
    @inline(__always)
    static func source(_ position: Int64, _ distance: Int64, _ start: Int32, _ end: Int32, _ undefined: UndefinedAreas) -> Int32? {
        guard start < end else { return nil }
        let p = position - distance, s = Int64(start), e = Int64(end)
        switch undefined {
        case .wrap:
            let m = (p - s) % (e - s)
            return Int32(s + (m < 0 ? m + (e - s) : m))
        case .repeat: return Int32(min(max(p, s), e - 1))
        case .transparent: return p >= s && p < e ? Int32(p) : nil
        }
    }
    /// An offset with the same result that keeps the shader's 32-bit `x − dx` in range: a wrap
    /// offset modulo the size, any other clamped to the size (past it, every pixel is already edge
    /// or transparent).
    static func reduced(_ d: Int32, _ size: Int, _ undefined: UndefinedAreas) -> Int32 {
        let n = Int64(max(size, 1))
        if undefined == .wrap {
            let m = Int64(d) % n
            return Int32(m < 0 ? m + n : m)
        }
        return Int32(min(max(Int64(d), -n), n))
    }
    struct Params: BitwiseCopyable { var dx: Int32; var dy: Int32; var edge: UInt32; var pad: UInt32 = 0 }
    public func encodeGPU(_ pass: GPUPass) throws {
        let b = pass.ctx.bounds
        try pass.dispatchOut("pca_offset", params: Params(dx: Self.reduced(horizontal, b.width, undefined), dy: Self.reduced(vertical, b.height, undefined),
                                                          edge: undefined.gpuEdge))
    }
}

/// Filter › Other › Custom: `Σ kernel·pixel / scale + offset/255` per colour channel over a 5×5
/// kernel (row-major, centre = index 12; shorter kernels zero-padded), alpha kept.
public struct CustomKernel: Filter, Hashable {
    public var kernel: [Float]
    public var scale: Float
    public var offset: Float
    public init(kernel: [Float], scale: Float = 1, offset: Float = 0) { self.kernel = kernel; self.scale = scale; self.offset = offset }
    public var label: String { "Custom" }
    public func halo(bounds: PixelRect) -> Halo { .reach(2) }

    /// Non-zero taps `(dx, dy, w)` in kernel order.
    var taps: [(Int32, Int32, Float)] {
        (0..<25).compactMap { i in
            guard i < kernel.count, kernel[i] != 0 else { return nil }
            return (Int32(i % 5) - 2, Int32(i / 5) - 2, kernel[i])
        }
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels, cc = ctx.colorChannels(n)
        let k = taps
        let s: Float = scale == 0 ? 1 : scale
        let off = offset / 255
        var res = src.crop(out)
        if k.isEmpty { return res }
        res.data.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelChunks(out.height, minChunk: 8) { rows in
                for oy in rows {
                    for ox in 0..<out.width {
                        let x = out.x0 + Int32(ox), y = out.y0 + Int32(oy)
                        let i = (oy * out.width + ox) * n
                        for c in 0..<cc {
                            var sum: Float = 0
                            for (dx, dy, w) in k { sum += src.get(x + dx, y + dy, c) * w }
                            rs.value[i + c] = sum / s + off
                        }
                    }
                }
            }
        }
        return res
    }

    struct Tap: BitwiseCopyable { var dx: Int32; var dy: Int32; var w: Float; var pad: Float = 0 }
    struct Params: BitwiseCopyable { var count: Int32; var scale: Float; var offset: Float; var pad: Float = 0 }
    public func encodeGPU(_ pass: GPUPass) throws {
        let t = taps.map { Tap(dx: $0.0, dy: $0.1, w: $0.2) }
        let p = Params(count: Int32(t.count), scale: scale == 0 ? 1 : scale, offset: offset / 255)
        try pass.dispatchOut("pca_custom", params: p, buffers: [try pass.buffer(t)])
    }
}
