// Port of photocraft-algo (crates/algo/src/blur2.rs: Spans, Prefix, shape_inside, lens_blur; shape_blur.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Shaped kernels as horizontal spans over per-row prefix sums of the premultiplied source, so a
// kernel of radius r costs O(r) per pixel. photocraft keeps the prefix sums in f64 for 16-bit
// precision; the Metal path keeps them as compensated float pairs (TwoSum, ~48-bit) and
// accumulates the span differences the same way.

import Metal
import PCFoundation

/// Built-in Shape Blur kernels.
public enum BlurShape: String, Codable, Sendable, Hashable, CaseIterable {
    case circle, ring, square, diamond, triangle, hexagon, star, heart, cross
}

/// Where Lens Blur reads depth.
public enum DepthSource: String, Codable, Sendable, Hashable, CaseIterable {
    case none, transparency, layerMask
}

enum SpanKit {
    /// A binary kernel as horizontal runs `(dy, dx0, dx1)` (inclusive) and its pixel count.
    struct Spans {
        var rows: [(Int32, Int32, Int32)]
        var count: Double

        /// Rasterizes `inside(u, v)` (u, v in −1…1) over a disc of radius `r` (photocraft `Spans::new`).
        init(_ r: Float, _ inside: (Float, Float) -> Bool) {
            let ri = PCAMath.i32(PCAMath.pos(r).rounded(.up))
            rows = []; count = 0
            if r < 0.5 { rows = [(0, 0, 0)]; count = 1; return }
            for dy in -ri...ri {
                var run: Int32? = nil
                for dx in -ri...(ri + 1) {
                    let hit = dx <= ri && inside(Float(dx) / r, Float(dy) / r)
                    if hit, run == nil { run = dx }
                    else if !hit, let s = run {
                        rows.append((dy, s, dx - 1)); count += Double(dx - s); run = nil
                    }
                }
            }
            if rows.isEmpty { rows = [(0, 0, 0)]; count = 1 }
        }
    }

    /// Even–odd point-in-polygon.
    static func inPoly(_ u: Float, _ v: Float, _ pts: [(Float, Float)]) -> Bool {
        var inside = false
        var j = pts.count - 1
        for i in 0..<pts.count {
            let (xi, yi) = pts[i], (xj, yj) = pts[j]
            if (yi > v) != (yj > v) && u < (xj - xi) * (v - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Radius of a regular `n`-gon (circumradius 1) in direction `theta` (photocraft `polygon_radius`).
    static func polygonRadius(_ theta: Float, _ n: UInt32, _ rot: Float) -> Float {
        let seg = PCAMath.tau / Float(n)
        let a = euclidMod(theta - rot, seg) - seg / 2
        return cosf(PCAMath.pi / Float(n)) / cosf(a)
    }

    static let starPoints: [(Float, Float)] = (0..<10).map { i in
        let r: Float = i % 2 == 0 ? 1 : 0.42
        let a = -PCAMath.pi / 2 + Float(i) * PCAMath.pi / 5
        return (r * cosf(a), r * sinf(a))
    }

    /// photocraft `shape_inside`.
    static func inside(_ shape: BlurShape, _ u: Float, _ v: Float) -> Bool {
        switch shape {
        case .circle: return u * u + v * v <= 1
        case .ring: let d = u * u + v * v; return d >= 0.36 && d <= 1
        case .square: return true
        case .diamond: return abs(u) + abs(v) <= 1
        case .triangle: return v <= 0.75 && abs(u) <= (v + 1) / 1.75
        case .hexagon: return (u * u + v * v).squareRoot() <= polygonRadius(atan2f(v, u), 6, 0)
        case .star: return inPoly(u, v, starPoints)
        case .heart:
            let x = u * 1.2, y = -v * 1.2 + 0.15
            let t = x * x + y * y - 1
            return t * t * t - x * x * y * y * y <= 0
        case .cross: return abs(u) <= 0.3 || abs(v) <= 0.3
        }
    }

    /// Per-row f64 prefix sums of an interleaved window: `(w + 1) × h × n` (photocraft `Prefix`).
    struct Prefix {
        let w: Int, h: Int, n: Int
        var data: [Double]
        init(_ p: [Float], _ w: Int, _ h: Int, _ n: Int) {
            self.w = w; self.h = h; self.n = n
            var d = [Double](repeating: 0, count: (w + 1) * h * n)
            d.withUnsafeMutableBufferPointer { db in
                let ds = UnsafeSendable(db)
                parallelChunks(h, minChunk: 8) { rows in
                    for y in rows {
                        let s = y * w * n, o = y * (w + 1) * n
                        for x in 0..<w { for c in 0..<n { ds.value[o + (x + 1) * n + c] = ds.value[o + x * n + c] + Double(p[s + x * n + c]) } }
                    }
                }
            }
            data = d
        }

        /// Kernel mean at window pixel `(x, y)` into `acc`.
        @inline(__always)
        func mean(_ spans: Spans, _ x: Int, _ y: Int, _ acc: inout [Double]) {
            for c in 0..<n { acc[c] = 0 }
            for (dy, a, b) in spans.rows {
                let yy = y + Int(dy)
                if yy < 0 || yy >= h { continue }
                let x0 = min(max(x + Int(a), 0), w), x1 = min(max(x + Int(b) + 1, 0), w)
                let row = yy * (w + 1) * n
                for c in 0..<n { acc[c] += data[row + x1 * n + c] - data[row + x0 * n + c] }
            }
            for c in 0..<n { acc[c] /= spans.count }
        }
    }

    struct Span: BitwiseCopyable { var dy: Int32; var a: Int32; var b: Int32; var pad: Int32 = 0 }
    struct Level: BitwiseCopyable { var start: Int32; var count: Int32; var invCount: Float; var pad: Float = 0 }

    static func gpuSpans(_ s: Spans) -> [Span] { s.rows.map { Span(dy: $0.0, a: $0.1, b: $0.2) } }

    struct PrefixParams: BitwiseCopyable { var width: Int32; var height: Int32; var premul: UInt32; var pad: UInt32 = 0 }
}

extension GPUPass {
    /// Per-row compensated prefix sums of `input` (covering `rect`, premultiplied first when asked):
    /// two (w + 1) × h textures, the high and low parts.
    func encodeRowPrefix(_ input: any MTLTexture, rect: PixelRect, premultiply: Bool) throws -> (any MTLTexture, any MTLTexture) {
        let hi = try texture(width: rect.width + 1, height: rect.height)
        let lo = try texture(width: rect.width + 1, height: rect.height)
        let p = SpanKit.PrefixParams(width: Int32(rect.width), height: Int32(rect.height), premul: premultiply ? 1 : 0)
        try dispatch("pca_row_prefix", params: p, textures: [input, hi, lo], width: rect.height, height: 1, threadgroup: (64, 1))
        return (hi, lo)
    }
}

/// Filter › Blur › Shape Blur: the mean over a built-in shape of radius 5–1000 px.
public struct ShapeBlur: Filter, Hashable {
    public var radius: Float
    public var shape: BlurShape
    public init(radius: Float = 10, shape: BlurShape = .circle) { self.radius = radius; self.shape = shape }
    public var label: String { "Shape Blur" }
    /// photocraft `shape_blur::radius`: at most 1000 px; non-finite → 0.
    var clampedRadius: Float { radius.isFinite ? clampf(radius, 0, 1000) : 0 }
    public func halo(bounds: PixelRect) -> Halo { .reach(clampedRadius) }
    var spans: SpanKit.Spans { let s = shape; return SpanKit.Spans(clampedRadius) { SpanKit.inside(s, $0, $1) } }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        var res = FloatImage(rect: out, channels: n)
        if n == 0 || out.isEmpty { return res }
        let sp = spans
        let w = src.rect.width, h = src.rect.height
        let pre = SpanKit.Prefix(FxUtil.premulWindow(src, src.rect, ctx.alpha), w, h, n)
        res.data.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelChunks(out.height, minChunk: 2) { rows in
                var acc = [Double](repeating: 0, count: n)
                var px = [Float](repeating: 0, count: n)
                for oy in rows {
                    let wy = Int(out.y0 - src.rect.y0) + oy
                    for ox in 0..<out.width {
                        pre.mean(sp, Int(out.x0 - src.rect.x0) + ox, wy, &acc)
                        for c in 0..<n { px[c] = Float(acc[c]) }
                        FxUtil.unpremulPx(&px, ctx.alpha)
                        let o = (oy * out.width + ox) * n
                        for c in 0..<n { rs.value[o + c] = px[c] }
                    }
                }
            }
        }
        return res
    }

    struct Params: BitwiseCopyable { var levels: Int32; var pad0: Int32 = 0; var pad1: Int32 = 0; var pad2: Int32 = 0 }
    public func encodeGPU(_ pass: GPUPass) throws {
        let sp = spans
        let (hi, lo) = try pass.encodeRowPrefix(pass.src, rect: pass.srcRect, premultiply: true)
        let spansBuf = try pass.buffer(SpanKit.gpuSpans(sp))
        let level = SpanKit.Level(start: 0, count: Int32(sp.rows.count), invCount: 0)
        let counts = try pass.buffer([Float(sp.count)])
        try pass.dispatchOut("pca_shape_blur", params: Params(levels: 1), textures: [hi, lo, pass.dst],
                             buffers: [spansBuf, try pass.buffer([level]), counts])
    }
}

/// Filter › Blur › Lens Blur: an iris-shaped bokeh (polygon of `blades` → circle by curvature),
/// highlights above the threshold brightened first; with a depth source the iris radius grows with
/// distance from the focal plane (8 interpolated levels); optional noise restores grain.
public struct LensBlur: Filter, Hashable {
    public var radius: Float
    public var blades: UInt32
    public var curvature: Float
    public var rotation: Float
    public var depth: DepthSource
    public var focalDistance: Float
    public var invertDepth: Bool
    public var brightness: Float
    public var threshold: Float
    public var noise: Float
    public var distribution: Distribution
    public var monochromatic: Bool
    public var seed: UInt32
    /// Depth for `.layerMask` (channel 0, document coordinates), supplied by the caller (not encoded).
    public var depthMap: FloatImage?

    public init(radius: Float = 15, blades: UInt32 = 6, curvature: Float = 0, rotation: Float = 0, depth: DepthSource = .none,
                focalDistance: Float = 0, invertDepth: Bool = false, brightness: Float = 0, threshold: Float = 255, noise: Float = 0,
                distribution: Distribution = .uniform, monochromatic: Bool = false, seed: UInt32 = 0, depthMap: FloatImage? = nil) {
        self.radius = radius; self.blades = blades; self.curvature = curvature; self.rotation = rotation; self.depth = depth
        self.focalDistance = focalDistance; self.invertDepth = invertDepth; self.brightness = brightness; self.threshold = threshold
        self.noise = noise; self.distribution = distribution; self.monochromatic = monochromatic; self.seed = seed; self.depthMap = depthMap
    }

    enum CodingKeys: String, CodingKey {
        case radius, blades, curvature, rotation, depth, focalDistance, invertDepth, brightness, threshold, noise, distribution, monochromatic, seed
    }

    public static func == (a: LensBlur, b: LensBlur) -> Bool {
        a.radius == b.radius && a.blades == b.blades && a.curvature == b.curvature && a.rotation == b.rotation && a.depth == b.depth
            && a.focalDistance == b.focalDistance && a.invertDepth == b.invertDepth && a.brightness == b.brightness
            && a.threshold == b.threshold && a.noise == b.noise && a.distribution == b.distribution
            && a.monochromatic == b.monochromatic && a.seed == b.seed && a.depthMap == b.depthMap
    }
    public func hash(into h: inout Hasher) { h.combine(radius); h.combine(blades); h.combine(seed); h.combine(depth) }

    public var label: String { "Lens Blur" }
    /// The kernel clamps the radius to 100 px: the source window is sized by what it uses (photocraft #8946).
    public func halo(bounds: PixelRect) -> Halo { .reach(min(radius, 100)) }
    static let levels = 8

    var boost: Float { clampf(brightness, 0, 100) / 100 * 4 }

    public var gpuChannels: GPUChannels { .perChannel }
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool {
        if boost <= 0 { return true }
        // The highlight boost needs luma of the whole pixel: Gray, RGB or Lab in one plane.
        return (ctx.mode.isGrayLike || ctx.mode.isRGBLike || ctx.mode == .lab) && ctx.colorChannels(channels) <= 3
    }

    func levelSpans() -> [SpanKit.Spans] {
        let rmax = clampf(radius, 0, 100)
        let b = min(max(blades, 3), 8)
        let curv = clampf(curvature, 0, 100) / 100
        let rot = PCAMath.radians(rotation)
        let iris: (Float, Float) -> Bool = { u, v in
            let rho = (u * u + v * v).squareRoot()
            let pr = SpanKit.polygonRadius(atan2f(v, u), b, rot - PCAMath.pi / 2)
            return rho <= pr + (1 - pr) * curv
        }
        return (0...Self.levels).map { SpanKit.Spans(rmax * Float($0) / Float(Self.levels), iris) }
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels, cc = ctx.colorChannels(n)
        let win = src.rect
        let ww = win.width, wh = win.height
        let levels = levelSpans()
        var p = FxUtil.premulWindow(src, win, ctx.alpha)
        let boost = self.boost
        if boost > 0 {
            let th = clampf(threshold, 0, 255) / 255
            let sub = ctx.subtractive
            p.withUnsafeMutableBufferPointer { pb in
                var st = [Float](repeating: 0, count: n)
                for i in 0..<(ww * wh) {
                    let b = i * n
                    let a: Float = ctx.alpha ? pb[b + n - 1] : 1
                    if a <= 0 { continue }
                    for c in 0..<n { st[c] = ctx.alpha && c < n - 1 ? pb[b + c] / a : pb[b + c] }
                    let l = st.withUnsafeBufferPointer { ctx.luma($0) }
                    let k = 1 + boost * smoothstep(th, th + 0.02, l)
                    for c in 0..<cc { pb[b + c] = sub ? a - (a - pb[b + c]) / k : pb[b + c] * k }
                }
            }
        }
        let pre = SpanKit.Prefix(p, ww, wh, n)
        let focal = clampf(focalDistance, 0, 255) / 255
        let amount = clampf(noise, 0, 100) / 100 * 0.25
        var res = FloatImage(rect: out, channels: n)
        let lv = Float(Self.levels)
        res.data.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelChunks(out.height, minChunk: 2) { rows in
                var acc = [Double](repeating: 0, count: n), acc2 = [Double](repeating: 0, count: n)
                var px = [Float](repeating: 0, count: n)
                for oy in rows {
                    let y = out.y0 + Int32(oy)
                    for ox in 0..<out.width {
                        let x = out.x0 + Int32(ox)
                        let wx = Int(x - win.x0), wy = Int(y - win.y0)
                        var d: Float? = nil
                        switch depth {
                        case .none: d = nil
                        case .transparency: d = ctx.alpha ? src.get(x, y, n - 1) : nil
                        case .layerMask: d = depthMap.map { $0.get(x, y, 0) }
                        }
                        if invertDepth, let dd = d { d = 1 - dd }
                        let level: Float = d.map { min(abs($0 - focal) * lv, lv) } ?? lv
                        let lo = Int(level.rounded(.down))
                        let f = level - Float(lo)
                        pre.mean(levels[lo], wx, wy, &acc)
                        if f > 1e-4 && lo < Self.levels {
                            pre.mean(levels[lo + 1], wx, wy, &acc2)
                            for c in 0..<n { acc[c] += (acc2[c] - acc[c]) * Double(f) }
                        }
                        for c in 0..<n { px[c] = Float(acc[c]) }
                        FxUtil.unpremulPx(&px, ctx.alpha)
                        if amount > 0 && (!ctx.alpha || px[n - 1] > 0) {
                            for c in 0..<cc {
                                let ch: UInt32 = monochromatic ? 0 : UInt32(c)
                                switch distribution {
                                case .uniform: px[c] += (hash01(x, y, ch + 200, seed) - 0.5) * 2 * amount
                                case .gaussian:
                                    let u1 = max(hash01(x, y, ch * 2 + 301, seed), 1e-7)
                                    let u2 = hash01(x, y, ch * 2 + 302, seed)
                                    px[c] += (-2 * logf(u1)).squareRoot() * cosf(PCAMath.tau * u2) * amount * 0.5
                                }
                            }
                        }
                        let o = (oy * out.width + ox) * n
                        for c in 0..<n { rs.value[o + c] = px[c] }
                    }
                }
            }
        }
        return res
    }

    struct BoostParams: BitwiseCopyable { var boost: Float; var th: Float; var lumaRGB: UInt32; var pad: UInt32 = 0 }
    struct Params: BitwiseCopyable {
        var depth: UInt32      // 0 none, 1 transparency, 2 map
        var invert: UInt32
        var focal: Float
        var amount: Float
        var gaussian: UInt32
        var mono: UInt32
        var seed: UInt32
        var levels: Int32
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let win = pass.srcRect
        var input = pass.src
        if boost > 0 {
            let t = try pass.texture(win)
            let bp = BoostParams(boost: boost, th: clampf(threshold, 0, 255) / 255, lumaRGB: pass.ctx.mode.isRGBLike ? 1 : 0)
            try pass.dispatch("pca_lens_boost", frame: pass.frame.with(src: win, out: win), params: bp, textures: [pass.src, t],
                              width: win.width, height: win.height)
            input = t
        }
        // The boosted window is already premultiplied; the plain source premultiplies in the prefix pass.
        let (hi, lo) = try pass.encodeRowPrefix(input, rect: win, premultiply: boost <= 0)
        let lv = levelSpans()
        var spans: [SpanKit.Span] = [], levels: [SpanKit.Level] = [], counts: [Float] = []
        for s in lv {
            levels.append(SpanKit.Level(start: Int32(spans.count), count: Int32(s.rows.count), invCount: 0))
            counts.append(Float(s.count))
            spans += SpanKit.gpuSpans(s)
        }
        var mapTex = pass.src
        var mapRect = PixelRect.empty
        var depthCode: UInt32 = 0
        switch depth {
        case .none: depthCode = 0
        case .transparency: depthCode = pass.ctx.alpha ? 1 : 0
        case .layerMask:
            if let m = depthMap { (mapTex, mapRect) = try pass.upload(m, channel: 0); depthCode = 2 }
        }
        let p = Params(depth: depthCode, invert: invertDepth ? 1 : 0, focal: clampf(focalDistance, 0, 255) / 255,
                       amount: clampf(noise, 0, 100) / 100 * 0.25, gaussian: distribution == .gaussian ? 1 : 0,
                       mono: monochromatic ? 1 : 0, seed: seed, levels: Int32(Self.levels))
        let f = pass.frame
        var mf = f
        mf.boundsOrigin = SIMD2(mapRect.x0, mapRect.y0); mf.boundsSize = SIMD2(Int32(mapRect.width), Int32(mapRect.height))
        try pass.dispatch("pca_lens_blur", frame: mf, params: p, textures: [hi, lo, pass.src, mapTex, pass.dst],
                          buffers: [try pass.buffer(spans), try pass.buffer(levels), try pass.buffer(counts)],
                          width: pass.out.width, height: pass.out.height)
    }
}

extension GPUPass {
    /// Uploads one channel of `img` (as .x) to a private texture; returns it and the rect it covers.
    func upload(_ img: FloatImage, channel: Int) throws -> (any MTLTexture, PixelRect) {
        let w = max(img.width, 1), h = max(img.height, 1)
        guard let buf = gpu.device.makeBuffer(length: w * h * 16, options: .storageModeShared) else {
            throw FilterError.gpuUnavailable("upload buffer")
        }
        let d = buf.contents().assumingMemoryBound(to: Float.self)
        memset(buf.contents(), 0, w * h * 16)
        let n = img.channels
        img.data.withUnsafeBufferPointer { s in
            for i in 0..<img.rect.area { d[i * 4] = s[i * n + channel] }
        }
        let t = try texture(width: w, height: h)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw FilterError.gpuUnavailable("blit") }
        blit.copy(from: buf, sourceOffset: 0, sourceBytesPerRow: w * 16, sourceBytesPerImage: w * h * 16,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: t, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        return (t, img.rect)
    }
}
