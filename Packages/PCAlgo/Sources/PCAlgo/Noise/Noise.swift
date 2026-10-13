// Port of photocraft-algo (crates/algo/src/noise.rs) and photocraft-engine's Despeckle preset
// (crates/engine/src/filters.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Add Noise (uniform / Gaussian, monochromatic), Median, Dust & Scratches, Despeckle.

import Foundation
import Metal
import MetalPerformanceShaders
import PCFoundation

/// Noise distribution (photocraft `Distribution`).
public enum Distribution: String, Codable, Sendable, Hashable, CaseIterable {
    case uniform, gaussian
}

/// Filter › Noise › Add Noise. Amount 0–400 %: 100 % spans ±50 % of the range (uniform); Gaussian
/// uses the same amount as ~2σ. Noise is a hash of document coordinates, channel and seed.
public struct AddNoise: Filter, Hashable {
    public var amount: Float
    public var distribution: Distribution
    public var monochromatic: Bool
    public var seed: UInt32
    public init(amount: Float = 10, distribution: Distribution = .uniform, monochromatic: Bool = false, seed: UInt32 = 0) {
        self.amount = amount; self.distribution = distribution; self.monochromatic = monochromatic; self.seed = seed
    }
    public var label: String { "Add Noise" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }

    @inline(__always)
    static func noise(_ x: Int32, _ y: Int32, _ ch: UInt32, _ seed: UInt32, _ dist: Distribution, _ a: Float) -> Float {
        switch dist {
        case .uniform:
            return (hash01(x, y, ch, seed) - 0.5) * 2 * a
        case .gaussian:
            let u1 = max(hash01(x, y, ch &* 2 &+ 101, seed), 1e-7)
            let u2 = hash01(x, y, ch &* 2 &+ 102, seed)
            return (-2 * logf(u1)).squareRoot() * cosf(PCAMath.tau * u2) * a * 0.5
        }
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels, cc = ctx.colorChannels(n)
        let a = max(amount, 0) / 100 * 0.5
        var res = src.crop(out)
        let (dist, mono, seed) = (distribution, monochromatic, seed)
        res.data.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelChunks(out.height, minChunk: 16) { rows in
                for oy in rows {
                    for ox in 0..<out.width {
                        let i = (oy * out.width + ox) * n
                        if ctx.alpha && rs.value[i + n - 1] <= 0 { continue }
                        let x = out.x0 + Int32(ox), y = out.y0 + Int32(oy)
                        for c in 0..<cc {
                            // Integer storage clamps on write; float surfaces keep the value.
                            rs.value[i + c] += AddNoise.noise(x, y, mono ? 0 : UInt32(c), seed, dist, a)
                        }
                    }
                }
            }
        }
        return res
    }

    struct Params: BitwiseCopyable { var a: Float; var gaussian: UInt32; var mono: UInt32; var seed: UInt32 }
    public func encodeGPU(_ pass: GPUPass) throws {
        let p = Params(a: max(amount, 0) / 100 * 0.5, gaussian: distribution == .gaussian ? 1 : 0, mono: monochromatic ? 1 : 0, seed: seed)
        try pass.dispatchOut("pca_add_noise", params: p)
    }
}

enum MedianKit {
    /// Half-width of the median disc on each row `dy` in `-r…r`: the largest `dx` with
    /// `dx² + dy² ≤ r² + r` (photocraft `disc_rows`).
    static func discRows(_ r: Int32) -> [Int32] {
        (-r...r).map { dy in
            let lim = r * r + r - dy * dy
            var hw = Int32(Double(lim).squareRoot())
            while hw * hw > lim { hw -= 1 }
            while (hw + 1) * (hw + 1) <= lim { hw += 1 }
            return hw
        }
    }

    /// Float total order (Rust `f32::total_cmp`) as an unsigned key.
    @inline(__always)
    static func key(_ v: Float) -> UInt32 {
        let b = v.bitPattern
        return b & 0x8000_0000 != 0 ? ~b : b | 0x8000_0000
    }

    /// Median over a disc of `radius`; with `threshold` (levels), a pixel is replaced only when it
    /// differs from the median by more than the threshold (photocraft `median`). Every channel,
    /// alpha included, is filtered independently; the value picked is the sample a selection
    /// under `total_cmp` picks. Radius 1 selects directly (`median_direct`); larger radii slide a
    /// rank histogram (`median_ranked`), in bands of rows run in parallel (the picked sample does
    /// not depend on the traversal).
    static func median(_ src: FloatImage, _ out: PixelRect, _ radius: Float, _ threshold: Float?) -> FloatImage {
        let r = PCAMath.i32(PCAMath.pos(radius).rounded(.toNearestOrAwayFromZero))
        if r == 0 { return src.crop(out) }
        let t = threshold.map { $0 / 255 }
        return r >= 2 ? medianRanked(src, out, r, t) : medianDirect(src, out, r, t)
    }

    /// photocraft `median_direct`: select the middle of every disc's samples.
    static func medianDirect(_ src: FloatImage, _ out: PixelRect, _ r: Int32, _ t: Float?) -> FloatImage {
        let n = src.channels
        let rows = discRows(r)
        var offs: [(Int32, Int32)] = []
        for (j, hw) in rows.enumerated() { for dx in -hw...hw { offs.append((dx, Int32(j) - r)) } }
        let mid = offs.count / 2
        var res = FloatImage(rect: out, channels: n)
        res.data.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelChunks(out.height, minChunk: 2) { range in
                var vals = [Float](repeating: 0, count: offs.count)
                for oy in range {
                    let y = out.y0 + Int32(oy)
                    for ox in 0..<out.width {
                        let x = out.x0 + Int32(ox)
                        for c in 0..<n {
                            for (k, (dx, dy)) in offs.enumerated() { vals[k] = src.get(x + dx, y + dy, c) }
                            let m = select(&vals, mid)
                            let o = src.get(x, y, c)
                            let v: Float
                            if let t, abs(o - m) <= t { v = o } else { v = m }
                            rs.value[(oy * out.width + ox) * n + c] = v
                        }
                    }
                }
            }
        }
        return res
    }

    /// photocraft `median_ranked` (Huang's sliding histogram over value ranks, with blocks of
    /// bins so the median crosses empty stretches quickly; serpentine traversal).
    static func medianRanked(_ src: FloatImage, _ out: PixelRect, _ r: Int32, _ t: Float?) -> FloatImage {
        let n = src.channels
        let rows = discRows(r)
        let count = rows.reduce(0) { $0 + Int(2 * $1 + 1) }
        let mid = count / 2
        let ow = out.width, ru = Int(r)
        var res = FloatImage(rect: out, channels: n)
        let bandRows = 32
        let bands = (out.height + bandRows - 1) / bandRows
        res.data.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelFor(bands) { b in
                let b0 = b * bandRows, b1 = min(out.height, b0 + bandRows)
                let bo = PixelRect(x0: out.x0, y0: out.y0 + Int32(b0), x1: out.x1, y1: out.y0 + Int32(b1))
                let win = bo.outset(by: r)
                let ww = win.width, wh = win.height, oh = bo.height
                var values = [Float](repeating: 0, count: ww * wh)
                var plane = [Int](repeating: 0, count: ww * wh)
                var hist: [Int] = [], blocks: [Int] = []
                for c in 0..<n {
                    var i = 0
                    for y in win.y0..<win.y1 { for x in win.x0..<win.x1 { values[i] = src.get(x, y, c); i += 1 } }
                    let eightBit = values.allSatisfy { v in
                        let k = (v * 255).rounded(.toNearestOrAwayFromZero)
                        return k >= 0 && k <= 255 && (k / 255).bitPattern == v.bitPattern
                    }
                    let levels: [Float]
                    if eightBit {
                        for j in 0..<values.count { plane[j] = Int((values[j] * 255).rounded(.toNearestOrAwayFromZero)) }
                        levels = (0..<256).map { Float($0) / 255 }
                    } else {
                        var keys = values.map { key($0) }
                        keys.sort()
                        var uniq: [UInt32] = []
                        uniq.reserveCapacity(keys.count)
                        for k in keys where uniq.last != k { uniq.append(k) }
                        for j in 0..<values.count {
                            // partition point: first unique key ≥ key(v)
                            let kv = key(values[j])
                            var lo = 0, hi = uniq.count
                            while lo < hi { let m = (lo + hi) / 2; if uniq[m] < kv { lo = m + 1 } else { hi = m } }
                            plane[j] = lo
                        }
                        levels = uniq.map { u in Float(bitPattern: u & 0x8000_0000 != 0 ? u & 0x7fff_ffff : ~u) }
                    }
                    let k = levels.count
                    let isq = max(Int(Double(k).squareRoot()), 1)
                    var isqrt = isq
                    while isqrt * isqrt > k { isqrt -= 1 }
                    while (isqrt + 1) * (isqrt + 1) <= k { isqrt += 1 }
                    let shift = Int.bitWidth - max(isqrt, 1).leadingZeroBitCount
                    let bs = 1 << shift
                    hist = [Int](repeating: 0, count: k)
                    blocks = [Int](repeating: 0, count: (k + bs - 1) / bs)
                    for (j, hw) in rows.enumerated() {
                        for x in (ru - Int(hw))...(ru + Int(hw)) {
                            let q = plane[j * ww + x]
                            hist[q] += 1; blocks[q >> shift] += 1
                        }
                    }
                    var m = 0, below = 0
                    for oy in 0..<oh {
                        for step in 0..<ow {
                            let ox = oy % 2 == 0 ? step : ow - 1 - step
                            let cx = ox + ru, cy = oy + ru
                            if oy > 0 || step > 0 {
                                for (j, hw32) in rows.enumerated() {
                                    let hw = Int(hw32)
                                    let gone: Int, new: Int
                                    if step == 0 {
                                        let x = cx + j - ru
                                        gone = (cy - 1 - hw) * ww + x; new = (cy + hw) * ww + x
                                    } else if oy % 2 == 0 {
                                        let y = (cy + j - ru) * ww
                                        gone = y + cx - 1 - hw; new = y + cx + hw
                                    } else {
                                        let y = (cy + j - ru) * ww
                                        gone = y + cx + 1 + hw; new = y + cx - hw
                                    }
                                    let g = plane[gone], nw = plane[new]
                                    hist[g] -= 1; blocks[g >> shift] -= 1
                                    hist[nw] += 1; blocks[nw >> shift] += 1
                                    if g < m { below -= 1 }
                                    if nw < m { below += 1 }
                                }
                            }
                            while below > mid {
                                if m & (bs - 1) == 0 && m > 0 && below - blocks[(m >> shift) - 1] > mid {
                                    below -= blocks[(m >> shift) - 1]; m -= bs
                                } else {
                                    m -= 1; below -= hist[m]
                                }
                            }
                            while true {
                                if m & (bs - 1) == 0 && (m >> shift) < blocks.count && below + blocks[m >> shift] <= mid {
                                    below += blocks[m >> shift]; m += bs
                                } else if below + hist[m] <= mid {
                                    below += hist[m]; m += 1
                                } else { break }
                            }
                            let mv = levels[m]
                            let x = bo.x0 + Int32(ox), y = bo.y0 + Int32(oy)
                            let o = src.get(x, y, c)
                            let v: Float
                            if let t, abs(o - mv) <= t { v = o } else { v = mv }
                            rs.value[((b0 + oy) * ow + ox) * n + c] = v
                        }
                    }
                }
            }
        }
        return res
    }

    /// The `k`th smallest of `v` under `total_cmp` (quickselect; `v` is reordered).
    static func select(_ v: inout [Float], _ k: Int) -> Float {
        var lo = 0, hi = v.count - 1
        while lo < hi {
            let pivot = key(v[(lo + hi) / 2])
            var i = lo, j = hi
            while i <= j {
                while key(v[i]) < pivot { i += 1 }
                while key(v[j]) > pivot { j -= 1 }
                if i <= j { v.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { return v[k] }
        }
        return v[k]
    }

    struct Params: BitwiseCopyable {
        var radius: Int32
        var rows: Int32
        var target: Int32
        var useThreshold: UInt32
        var threshold: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    static func encode(_ pass: GPUPass, radius: Float, threshold: Float?) throws {
        let r = PCAMath.i32(PCAMath.pos(radius).rounded(.toNearestOrAwayFromZero))
        if r == 0 { try pass.dispatchOut("pca_copy", params: NoParams()); return }
        if r == 1 && OtherKit.useMPS && !pass.ctx.alpha {
            // Radius 1's disc (dx² + dy² ≤ 2) is the 3×3 square: MPSImageMedian picks the same
            // 5th of 9 samples (exact); reads outside the source are 0 as photocraft's `get`.
            // (MPS doesn't take the median of alpha, which photocraft does: alpha images use MSL.)
            let m = MPSImageMedian(device: pass.gpu.device, kernelDiameter: 3)
            m.edgeMode = .zero
            m.offset = MPSOffset(x: Int(pass.out.x0 - pass.srcRect.x0), y: Int(pass.out.y0 - pass.srcRect.y0), z: 0)
            m.clipRect = MTLRegionMake2D(0, 0, pass.out.width, pass.out.height)
            if let t = threshold {
                let med = try pass.texture(pass.out)
                m.encode(commandBuffer: pass.commandBuffer, sourceTexture: pass.src, destinationTexture: med)
                let p = Params(radius: 1, rows: 0, target: 0, useThreshold: 1, threshold: t / 255)
                try pass.dispatchOut("pca_median_threshold", params: p, textures: [pass.src, med, pass.dst])
            } else {
                m.encode(commandBuffer: pass.commandBuffer, sourceTexture: pass.src, destinationTexture: pass.dst)
            }
            return
        }
        let rows = discRows(r)
        let count = rows.reduce(0) { $0 + Int(2 * $1 + 1) }
        let p = Params(radius: r, rows: Int32(rows.count), target: Int32(count / 2), useThreshold: threshold == nil ? 0 : 1,
                       threshold: (threshold ?? 0) / 255)
        if r <= 8 {
            // Tile + reach in threadgroup memory: (16 + 2r)² float4 ≤ 16 KB.
            let side = 16 + 2 * Int(r)
            try pass.dispatch("pca_median_tg", params: p, textures: [pass.src, pass.dst], buffers: [try pass.buffer(rows)],
                              width: pass.out.width, height: pass.out.height, threadgroup: (16, 16), threadgroupMemory: [side * side * 16])
        } else {
            try pass.dispatchOut("pca_median", params: p, buffers: [try pass.buffer(rows)])
        }
    }
}

/// Filter › Noise › Median over a disc of `radius`.
public struct Median: Filter, Hashable {
    public var radius: Float
    public init(radius: Float = 1) { self.radius = radius }
    public var label: String { "Median" }
    public func halo(bounds: PixelRect) -> Halo { .reach(radius) }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage { MedianKit.median(src, out, radius, nil) }
    public func encodeGPU(_ pass: GPUPass) throws { try MedianKit.encode(pass, radius: radius, threshold: nil) }
}

/// Filter › Noise › Dust & Scratches: the median where a pixel differs from it by more than
/// `threshold` levels.
public struct DustAndScratches: Filter, Hashable {
    public var radius: Float
    public var threshold: Float
    public init(radius: Float = 1, threshold: Float = 0) { self.radius = radius; self.threshold = threshold }
    public var label: String { "Dust & Scratches" }
    public func halo(bounds: PixelRect) -> Halo { .reach(radius) }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage { MedianKit.median(src, out, radius, threshold) }
    public func encodeGPU(_ pass: GPUPass) throws { try MedianKit.encode(pass, radius: radius, threshold: threshold) }
}

/// Filter › Noise › Despeckle: photocraft's one-step preset, Surface Blur radius 2, threshold 12.
public struct Despeckle: Filter, Hashable {
    public init() {}
    var surface: SurfaceBlur { SurfaceBlur(radius: 2, threshold: 12) }
    public var label: String { "Despeckle" }
    public func halo(bounds: PixelRect) -> Halo { surface.halo(bounds: bounds) }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage { surface.cpu(src, out: out, ctx: ctx) }
    public func encodeGPU(_ pass: GPUPass) throws { try surface.encodeGPU(pass) }
}
