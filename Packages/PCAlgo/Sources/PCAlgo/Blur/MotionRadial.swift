// Port of photocraft-algo (crates/algo/src/blur.rs: motion, radial, average_samples; blur/radial.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Motion Blur: the mean of bilinear samples along a line centred on each pixel. The offsets are
// the same for every pixel, so their bilinear taps are merged once (first-seen order) into a fixed
// kernel applied to the premultiplied source. photocraft also has an FFT overlap-save path for
// distances ≥ 64 (blur/motion_fft.rs) that matches this kernel within float tolerance; the Metal
// kernel applies the taps directly.
//
// Radial Blur: Spin (an arc of `amount` degrees) or Zoom (a ray toward the centre) of bilinear
// premultiplied samples, `ceil(path length)` intervals capped by quality (64 / 256 / 4096). The
// sample rotations/scales are tabulated once on the CPU (photocraft's radial `Plan`) and shared by
// both paths, so positions agree bit for bit.

import Metal
import PCFoundation

enum MotionKit {
    /// Sample offsets of a motion blur relative to the pixel centre (photocraft `motion_offsets`).
    static func offsets(_ angle: Float, _ distance: Float) -> [(Float, Float)] {
        let d = abs(distance)
        let rad = PCAMath.radians(angle)
        let s = sinf(rad), c = cosf(rad)
        let steps = Int32(d.rounded(.up))
        return (0...steps).map { i in
            let t = Float(i) / Float(steps) - 0.5
            return (c * d * t, -s * d * t)
        }
    }

    /// Merged bilinear taps `(dx, dy, weight)` in first-seen order.
    static func taps(_ angle: Float, _ distance: Float) -> [(Int32, Int32, Float)] {
        let offs = offsets(angle, distance)
        let k = 1 / Float(offs.count)
        var taps: [(Int32, Int32, Float)] = []
        var slot: [Int64: Int] = [:]
        for (ox, oy) in offs {
            let x0 = ox.rounded(.down), y0 = oy.rounded(.down)
            let ax = ox - x0, ay = oy - y0
            let ix = Int32(x0), iy = Int32(y0)
            for (dx, dy, w) in [(Int32(0), Int32(0), (1 - ax) * (1 - ay)), (1, 0, ax * (1 - ay)), (0, 1, (1 - ax) * ay), (1, 1, ax * ay)] {
                if w <= 0 { continue }
                let key = Int64(ix + dx) << 32 | Int64(UInt32(bitPattern: iy + dy))
                let i: Int
                if let s = slot[key] { i = s } else { taps.append((ix + dx, iy + dy, 0)); i = taps.count - 1; slot[key] = i }
                taps[i].2 += w * k
            }
        }
        return taps
    }

    struct Tap: BitwiseCopyable { var dx: Int32; var dy: Int32; var w: Float; var pad: Float = 0 }
    struct Params: BitwiseCopyable { var count: Int32; var pad0: Int32 = 0; var pad1: Int32 = 0; var pad2: Int32 = 0 }
}

/// Filter › Blur › Motion Blur: angle degrees, distance px.
public struct MotionBlur: Filter, Hashable {
    public var angle: Float
    public var distance: Float
    public init(angle: Float = 0, distance: Float = 10) { self.angle = angle; self.distance = distance }
    public var label: String { "Motion Blur" }
    public func halo(bounds: PixelRect) -> Halo { .radius(Int32((abs(distance) / 2).rounded(.up)) + 2) }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        if abs(distance) < 0.5 { return src.crop(out) }
        let taps = MotionKit.taps(angle, distance)
        let reach = taps.map { max(abs($0.0), abs($0.1)) }.max() ?? 0
        let n = src.channels
        let win = out.outset(by: reach)
        let ww = win.width
        let pw = FxUtil.premulWindow(src, win, ctx.alpha)
        var res = FloatImage(rect: out, channels: n)
        let ow = out.width, r = Int(reach)
        pw.withUnsafeBufferPointer { p in
            res.data.withUnsafeMutableBufferPointer { rb in
                let rs = UnsafeSendable(rb)
                parallelChunks(out.height, minChunk: 4) { rows in
                    for oy in rows {
                        let row = oy * ow * n
                        for (dx, dy, w) in taps {
                            let start = ((oy + r + Int(dy)) * ww + r + Int(dx)) * n
                            for j in 0..<(ow * n) { rs.value[row + j] += w * p[start + j] }
                        }
                        if ctx.alpha {
                            var i = row
                            while i < row + ow * n {
                                let a = rs.value[i + n - 1]
                                for c in 0..<(n - 1) { rs.value[i + c] = a > 1e-7 ? rs.value[i + c] / a : 0 }
                                i += n
                            }
                        }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        if abs(distance) < 0.5 { try pass.dispatchOut("pca_copy", params: NoParams()); return }
        let taps = MotionKit.taps(angle, distance).map { MotionKit.Tap(dx: $0.0, dy: $0.1, w: $0.2) }
        try pass.dispatchOut("pca_motion_blur", params: MotionKit.Params(count: Int32(taps.count)), buffers: [try pass.buffer(taps)])
    }
}

/// Radial blur method.
public enum RadialMethod: String, Codable, Sendable, Hashable, CaseIterable { case spin, zoom }

/// Sampling quality for Radial Blur: up to 64 / 256 / 4096 intervals per pixel.
public enum RadialQuality: String, Codable, Sendable, Hashable, CaseIterable { case draft, good, best }

enum RadialKit {
    static func maxIntervals(_ q: RadialQuality) -> Int {
        switch q { case .draft: 64; case .good: 256; case .best: 4096 }
    }

    /// photocraft `radial_intervals`.
    static func intervals(_ pathLength: Float, _ q: RadialQuality) -> Int {
        if pathLength.isNaN { return 1 }
        return Int(clampf(pathLength.rounded(.up), 1, Float(maxIntervals(q))))
    }

    /// Start of the table for `n` intervals: tables for 1… are packed, each with n + 1 entries.
    @inline(__always) static func tableStart(_ n: Int) -> Int { (n - 1) * (n + 2) / 2 }

    /// (sin, cos) of each Spin sample angle, or (0, scale) of each Zoom sample, for 1…maxN intervals.
    static func table(_ method: RadialMethod, extent: Float, maxN: Int) -> [SIMD2<Float>] {
        var t: [SIMD2<Float>] = []
        t.reserveCapacity(tableStart(maxN + 1))
        for n in 1...maxN {
            for i in 0...n {
                switch method {
                case .spin:
                    let a = (Float(i) / Float(n) - 0.5) * extent
                    t.append(SIMD2(sinf(a), cosf(a)))
                case .zoom:
                    t.append(SIMD2(0, 1 - extent * Float(i) / Float(n)))
                }
            }
        }
        return t
    }

    struct Params: BitwiseCopyable {
        var center: SIMD2<Float>
        var extent: Float
        var spin: UInt32
        var maxN: Int32
        var pad0: Int32 = 0
        var pad1: Int32 = 0
        var pad2: Int32 = 0
    }
}

/// Filter › Blur › Radial Blur: amount 1–100, Spin or Zoom, quality, centre as a fraction of the
/// bounds.
public struct RadialBlur: Filter, Hashable {
    public var amount: Float
    public var method: RadialMethod
    public var quality: RadialQuality
    public var centerX: Float
    public var centerY: Float
    public init(amount: Float = 10, method: RadialMethod = .spin, quality: RadialQuality = .good, centerX: Float = 0.5, centerY: Float = 0.5) {
        self.amount = amount; self.method = method; self.quality = quality; self.centerX = centerX; self.centerY = centerY
    }

    enum CodingKeys: String, CodingKey { case amount, method, quality, centerX, centerY }
    /// photocraft `#[serde(default)] quality` (older parameters have none: Good).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decode(Float.self, forKey: .amount)
        method = try c.decode(RadialMethod.self, forKey: .method)
        quality = try c.decodeIfPresent(RadialQuality.self, forKey: .quality) ?? .good
        centerX = try c.decode(Float.self, forKey: .centerX)
        centerY = try c.decode(Float.self, forKey: .centerY)
    }
    public var label: String { "Radial Blur" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    func center(_ b: PixelRect) -> (Float, Float) {
        (Float(b.x0) + Float(b.width) * centerX, Float(b.y0) + Float(b.height) * centerY)
    }
    var extent: Float {
        let a = clampf(amount, 0, 100)
        return method == .spin ? PCAMath.radians(a) : a / 200
    }
    /// Interval ceiling reachable in `out` (photocraft `Plan::for_area`: the farthest corner).
    func maxN(_ out: PixelRect, _ c: (Float, Float)) -> Int {
        var radius: Float = 0
        for y in [out.y0, out.y1 - 1] {
            for x in [out.x0, out.x1 - 1] {
                let dx = Float(x) + 0.5 - c.0, dy = Float(y) + 0.5 - c.1
                radius = max(radius, (dx * dx + dy * dy).squareRoot())
            }
        }
        return RadialKit.intervals(extent * radius, quality)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        var res = FloatImage(rect: out, channels: n)
        if out.isEmpty || n == 0 { return res }
        let c = center(ctx.bounds)
        let ext = extent
        let table = RadialKit.table(method, extent: ext, maxN: maxN(out, c))
        let spin = method == .spin, q = quality, alpha = ctx.alpha
        let sr = src.rect
        src.data.withUnsafeBufferPointer { sp in
            res.data.withUnsafeMutableBufferPointer { rb in
                let rs = UnsafeSendable(rb)
                parallelChunks(out.height, minChunk: 1) { rows in
                    var tmp = [Float](repeating: 0, count: n), acc = [Float](repeating: 0, count: n)
                    tmp.withUnsafeMutableBufferPointer { tb in
                        let tp = tb.baseAddress!
                        for oy in rows {
                            let y = out.y0 + Int32(oy)
                            let dy = Float(y) + 0.5 - c.1
                            for ox in 0..<out.width {
                                let x = out.x0 + Int32(ox)
                                let dx = Float(x) + 0.5 - c.0
                                let r = (dx * dx + dy * dy).squareRoot()
                                let cnt = RadialKit.intervals(ext * r, q)
                                let start = RadialKit.tableStart(cnt)
                                for k in 0..<n { acc[k] = 0 }
                                for i in 0...cnt {
                                    let t = table[start + i]
                                    let (sx, sy) = spin ? (c.0 + dx * t.y - dy * t.x, c.1 + dx * t.x + dy * t.y) : (c.0 + dx * t.y, c.1 + dy * t.y)
                                    // photocraft `Image::sample` with Edge::Transparent over the source rect.
                                    DistortKit.sample(sp, sr, n, sx, sy, .transparent, sr, alpha, tp)
                                    let a: Float = alpha ? tp[n - 1] : 1
                                    for k in 0..<n { acc[k] += alpha && k < n - 1 ? tp[k] * a : tp[k] }
                                }
                                let kk = 1 / Float(cnt + 1)
                                let o = (oy * out.width + ox) * n
                                for k in 0..<n { rs.value[o + k] = acc[k] * kk }
                                if alpha {
                                    let av = acc[n - 1] * kk
                                    for k in 0..<(n - 1) { rs.value[o + k] = av > 1e-7 ? rs.value[o + k] / av : 0 }
                                }
                            }
                        }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let c = center(pass.ctx.bounds)
        let mx = maxN(pass.out, c)
        let table = RadialKit.table(method, extent: extent, maxN: mx)
        // Counts never exceed the farthest corner's (the table's size); the clamp guards the table.
        let p = RadialKit.Params(center: SIMD2(c.0, c.1), extent: extent, spin: method == .spin ? 1 : 0, maxN: Int32(mx))
        try pass.dispatchOut("pca_radial_blur", params: p, buffers: [try pass.buffer(table)])
    }
}
