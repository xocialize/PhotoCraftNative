// Port of photocraft-algo (crates/algo/src/gallery.rs, gallery/spin_plan.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Blur Gallery: Tilt-Shift, Iris and Field (spatially varying Gaussian blur), Spin (rotational
// blur inside ellipses) and Path (motion along paths). The varying blur interpolates a stack of
// seven Gaussian levels (σ 0 and smax/32 … smax, each fxutil's three-box cascade over the
// premultiplied source window) with hat weights of the per-pixel σ, so cost grows with the
// number of levels, not the blur size (docs/iris-blur-performance.md, tilt-shift-performance.md).

import Metal
import PCFoundation

/// Iris Blur pin.
public struct IrisPin: Codable, Sendable, Hashable {
    public var x: Float = 0.5
    public var y: Float = 0.5
    public var radiusX: Float = 0.35
    public var radiusY: Float = 0.25
    /// Ellipse rotation in degrees.
    public var angle: Float = 0
    /// 0 = ellipse, 100 = rounded rectangle.
    public var roundness: Float = 0
    /// Sharp core as a fraction of the ellipse (0–1).
    public var feather: Float = 0.5
    /// Blur at and beyond the ellipse, px.
    public var blur: Float = 15
    public init(x: Float = 0.5, y: Float = 0.5, radiusX: Float = 0.35, radiusY: Float = 0.25, angle: Float = 0, roundness: Float = 0,
                feather: Float = 0.5, blur: Float = 15) {
        self.x = x; self.y = y; self.radiusX = radiusX; self.radiusY = radiusY; self.angle = angle; self.roundness = roundness
        self.feather = feather; self.blur = blur
    }
    enum CodingKeys: String, CodingKey { case x, y, radiusX, radiusY, angle, roundness, feather, blur }
    /// photocraft `#[serde(default)]`: every field falls back to `IrisPin::default()`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = IrisPin()
        x = try c.decodeIfPresent(Float.self, forKey: .x) ?? d.x
        y = try c.decodeIfPresent(Float.self, forKey: .y) ?? d.y
        radiusX = try c.decodeIfPresent(Float.self, forKey: .radiusX) ?? d.radiusX
        radiusY = try c.decodeIfPresent(Float.self, forKey: .radiusY) ?? d.radiusY
        angle = try c.decodeIfPresent(Float.self, forKey: .angle) ?? d.angle
        roundness = try c.decodeIfPresent(Float.self, forKey: .roundness) ?? d.roundness
        feather = try c.decodeIfPresent(Float.self, forKey: .feather) ?? d.feather
        blur = try c.decodeIfPresent(Float.self, forKey: .blur) ?? d.blur
    }
}

/// Field Blur pin: a blur amount at a point.
public struct FieldPin: Codable, Sendable, Hashable {
    public var x: Float = 0.5
    public var y: Float = 0.5
    public var blur: Float = 15
    public init(x: Float = 0.5, y: Float = 0.5, blur: Float = 15) { self.x = x; self.y = y; self.blur = blur }
    enum CodingKeys: String, CodingKey { case x, y, blur }
    /// photocraft `#[serde(default)]`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = FieldPin()
        x = try c.decodeIfPresent(Float.self, forKey: .x) ?? d.x
        y = try c.decodeIfPresent(Float.self, forKey: .y) ?? d.y
        blur = try c.decodeIfPresent(Float.self, forKey: .blur) ?? d.blur
    }
}

/// Spin Blur pin: an ellipse whose content is rotated about its centre.
public struct SpinPin: Codable, Sendable, Hashable {
    public var x: Float = 0.5
    public var y: Float = 0.5
    public var radiusX: Float = 0.3
    public var radiusY: Float = 0.3
    public var angle: Float = 0
    /// Blur arc in degrees.
    public var blurAngle: Float = 15
    public init(x: Float = 0.5, y: Float = 0.5, radiusX: Float = 0.3, radiusY: Float = 0.3, angle: Float = 0, blurAngle: Float = 15) {
        self.x = x; self.y = y; self.radiusX = radiusX; self.radiusY = radiusY; self.angle = angle; self.blurAngle = blurAngle
    }
    enum CodingKeys: String, CodingKey { case x, y, radiusX, radiusY, angle, blurAngle }
    /// photocraft `#[serde(default)]`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = SpinPin()
        x = try c.decodeIfPresent(Float.self, forKey: .x) ?? d.x
        y = try c.decodeIfPresent(Float.self, forKey: .y) ?? d.y
        radiusX = try c.decodeIfPresent(Float.self, forKey: .radiusX) ?? d.radiusX
        radiusY = try c.decodeIfPresent(Float.self, forKey: .radiusY) ?? d.radiusY
        angle = try c.decodeIfPresent(Float.self, forKey: .angle) ?? d.angle
        blurAngle = try c.decodeIfPresent(Float.self, forKey: .blurAngle) ?? d.blurAngle
    }
}

/// Path Blur path: a polyline (fractions of the bounds) giving the motion direction.
public struct BlurPath: Codable, Sendable, Hashable {
    public var points: [SIMD2<Float>] = [SIMD2(0.2, 0.5), SIMD2(0.8, 0.5)]
    /// Blur length in px.
    public var speed: Float = 50
    /// 0–100: how much the blur fades toward the path's end.
    public var taper: Float = 0
    public init(points: [SIMD2<Float>] = [SIMD2(0.2, 0.5), SIMD2(0.8, 0.5)], speed: Float = 50, taper: Float = 0) {
        self.points = points; self.speed = speed; self.taper = taper
    }
    enum CodingKeys: String, CodingKey { case points, speed, taper }
    /// photocraft `#[serde(default)]`; points are `[x, y]` pairs.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = BlurPath()
        points = try c.decodeIfPresent([SIMD2<Float>].self, forKey: .points) ?? d.points
        speed = try c.decodeIfPresent(Float.self, forKey: .speed) ?? d.speed
        taper = try c.decodeIfPresent(Float.self, forKey: .taper) ?? d.taper
    }
}

enum GalleryKit {
    /// Gaussian σ for a gallery blur amount in px.
    static func sigmaOf(_ blur: Float) -> Float { clampf(blur, 0, 500) * 0.6 }
    /// Pixels read beyond an output tile for a maximum blur amount.
    static func reach(_ blur: Float) -> Float { 3 * sigmaOf(blur) + 2 }
    static let levels = 6

    static func shortSide(_ b: PixelRect) -> Float { max(Float(min(b.width, b.height)), 1) }

    /// Level σs: 0, then smax / 2^(LEVELS−1) … smax.
    static func levelSigmas(_ smax: Float) -> [Float] {
        [0] + (0..<levels).map { k in smax / Float(1 << (levels - 1 - k)) }
    }

    /// Hat-function weight of level k for σ s.
    @inline(__always)
    static func weight(_ lv: [Float], _ k: Int, _ s: Float) -> Float {
        let c = lv[k]
        if k > 0 && s >= lv[k - 1] && s <= c { return (s - lv[k - 1]) / max(c - lv[k - 1], 1e-6) }
        if k + 1 < lv.count && s >= c && s <= lv[k + 1] { return (lv[k + 1] - s) / max(lv[k + 1] - c, 1e-6) }
        if k + 1 == lv.count && s >= c { return 1 }
        return 0
    }

    /// photocraft `variable_blur`: per-pixel σ (`sigma(x, y)`, clamped to ≤ smax) interpolating the
    /// level stack. `trim` lets each level's buffer end at the output plus its own box reach (Iris,
    /// Tilt-Shift); the trailing clamp then cannot reach the output, so results are unchanged.
    static func variableBlur(_ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext, _ smax: Float, trim: Bool,
                             _ sigma: (Float, Float) -> Float) -> FloatImage {
        let n = src.channels
        if n == 0 || out.isEmpty { return FloatImage(rect: out, channels: n) }
        if smax < 0.3 { return src.crop(out) }
        let win = src.rect
        let ww = win.width, wh = win.height
        let lv = levelSigmas(smax)
        var sig = [Float](repeating: 0, count: out.area)
        for i in 0..<out.area {
            let (x, y) = pixelXY(out, i)
            sig[i] = clampf(sigma(Float(x) + 0.5, Float(y) + 0.5), 0, smax)
        }
        var p = src.data
        premultiply(&p, n, ctx.alpha)
        var acc = [Float](repeating: 0, count: out.area * n)
        for (k, lvk) in lv.enumerated() {
            if !sig.contains(where: { weight(lv, k, $0) > 0 }) { continue }
            var level: [Float]
            var lw = ww
            if k == 0 {
                level = p
            } else {
                let doTrim = trim && win.intersect(out) == out
                let reach = (!doTrim || lvk < 0.3) ? 0 : Int32(FxUtil.gaussBoxRadii(lvk).reduce(0, +))
                lw = doTrim ? Int(min(out.x1 + reach, win.x1) - win.x0) : ww
                let lh = doTrim ? Int(min(out.y1 + reach, win.y1) - win.y0) : wh
                if doTrim {
                    level = []
                    level.reserveCapacity(lw * lh * n)
                    for row in 0..<lh { level.append(contentsOf: p[(row * ww * n)..<(row * ww * n + lw * n)]) }
                } else { level = p }
                FxUtil.gaussBlurN(&level, lw, doTrim ? lh : wh, n, lvk)
            }
            for i in 0..<out.area {
                let wk = weight(lv, k, sig[i])
                if wk <= 0 { continue }
                let (x, y) = pixelXY(out, i)
                let o = (Int(y - win.y0) * lw + Int(x - win.x0)) * n
                for c in 0..<n { acc[i * n + c] += level[o + c] * wk }
            }
        }
        unpremultiply(&acc, n, ctx.alpha)
        return FloatImage(rect: out, channels: n, data: acc)
    }

    /// Iris pin geometry prepared once (photocraft `PreparedIris`).
    struct PreparedIris: BitwiseCopyable {
        var cx: Float, cy: Float, rx: Float, ry: Float
        var sin: Float, cos: Float, exponent: Float, feather: Float
        var blur: Float, pad0: Float = 0, pad1: Float = 0, pad2: Float = 0

        init(_ p: IrisPin, _ b: PixelRect) {
            let ss = shortSide(b)
            let angle = p.angle.isFinite ? p.angle : 0
            let r = PCAMath.radians(angle)
            cx = Float(b.x0) + p.x * Float(b.width); cy = Float(b.y0) + p.y * Float(b.height)
            rx = max(p.radiusX, 1e-3) * ss; ry = max(p.radiusY, 1e-3) * ss
            sin = sinf(r); cos = cosf(r)
            exponent = 2 + clampf(p.roundness, 0, 100) / 100 * 6
            feather = clampf(p.feather, 0, 0.999)
            blur = sigmaOf(p.blur)
        }

        func sigma(_ x: Float, _ y: Float) -> Float {
            let dx = x - cx, dy = y - cy
            let u = (dx * cos + dy * sin) / rx, v = (-dx * sin + dy * cos) / ry
            var e: Float
            if abs(u) >= 1 || abs(v) >= 1 { e = .infinity }
            else if abs(exponent - 2) < 1e-3 { e = (u * u + v * v).squareRoot() }
            else { e = powf(powf(abs(u), exponent) + powf(abs(v), exponent), 1 / exponent) }
            if !e.isFinite { e = .infinity }
            return blur * smoothstep(feather, 1, e)
        }
    }

    /// σ map kinds for the Metal path.
    enum SigmaKind: UInt32 { case tiltShift = 0, iris = 1, field = 2 }

    struct SigmaParams: BitwiseCopyable {
        var kind: UInt32
        var count: Int32
        var smax: Float
        var ss: Float
        var center: SIMD2<Float>
        var normal: SIMD2<Float>
        var f0: Float
        var f1: Float
        var pad0: Float = 0
        var pad1: Float = 0
    }

    struct AccumParams: BitwiseCopyable {
        var lo: Float
        var mid: Float
        var hi: Float
        var first: UInt32
        var last: UInt32
        var hasLo: UInt32
        var hasHi: UInt32
        var pad: UInt32 = 0
    }

    /// The level stack on the GPU: σ map, premultiplied window, each level blurred from it and
    /// accumulated where its weight is positive, then unpremultiplied into `pass.dst`.
    static func encodeVariableBlur(_ pass: GPUPass, smax: Float, sigma: SigmaParams, pins: (any MTLBuffer)?) throws {
        if smax < 0.3 { try pass.dispatchOut("pca_copy", params: NoParams()); return }
        let win = pass.srcRect, out = pass.out
        let wf = pass.frame.with(src: win, out: win)
        let p = try pass.texture(win)
        try pass.dispatch("pca_premul_copy", frame: wf, params: NoParams(), textures: [pass.src, p], width: win.width, height: win.height)
        let sig = try pass.texture(out)
        var sp = sigma
        sp.smax = smax
        try pass.dispatch("pca_gal_sigma", params: sp, textures: [sig], buffers: pins.map { [$0] } ?? [try pass.buffer([Float(0)])],
                          width: out.width, height: out.height)
        let lv = levelSigmas(smax)
        var acc = try pass.texture(out)
        for (k, lvk) in lv.enumerated() {
            let level = k == 0 ? p : try pass.encodeGaussBlurN(p, rect: win, sigma: lvk)
            let ap = AccumParams(lo: k > 0 ? lv[k - 1] : 0, mid: lvk, hi: k + 1 < lv.count ? lv[k + 1] : 0, first: k == 0 ? 1 : 0,
                                 last: k + 1 == lv.count ? 1 : 0, hasLo: k > 0 ? 1 : 0, hasHi: k + 1 < lv.count ? 1 : 0)
            let next = k + 1 == lv.count ? pass.dst : try pass.texture(out)
            // Frame: `src` is the level (covering the window), `out` the output.
            try pass.dispatch("pca_gal_accum", frame: pass.frame.with(src: win), params: ap, textures: [acc, level, sig, next],
                              width: out.width, height: out.height)
            if level !== p { pass.recycle(level) }
            pass.recycle(acc)
            acc = next
        }
        pass.recycle(p); pass.recycle(sig)
    }

    /// The bilinear premultiplied sampler of Spin and Path (edges clamped to `clip`).
    struct ClipParams: BitwiseCopyable { var clipOrigin: SIMD2<Int32>; var clipSize: SIMD2<Int32> }
}

/// Filter › Blur Gallery › Tilt-Shift: a sharp band through the centre at `angle`, blurring with
/// distance beyond `focus` over `transition` (fractions of the bounds' shorter side).
public struct TiltShift: Filter, Hashable {
    public var blur: Float
    public var centerX: Float
    public var centerY: Float
    public var angle: Float
    public var focus: Float
    public var transition: Float
    public init(blur: Float = 15, centerX: Float = 0.5, centerY: Float = 0.5, angle: Float = 0, focus: Float = 0.1, transition: Float = 0.15) {
        self.blur = blur; self.centerX = centerX; self.centerY = centerY; self.angle = angle; self.focus = focus; self.transition = transition
    }
    public var label: String { "Tilt-Shift" }
    public func halo(bounds: PixelRect) -> Halo { .reach(GalleryKit.reach(blur)) }

    func geometry(_ b: PixelRect) -> (cx: Float, cy: Float, nx: Float, ny: Float, ss: Float, smax: Float, f0: Float, f1: Float) {
        let ss = GalleryKit.shortSide(b)
        let r = PCAMath.radians(angle)
        let smax = max(GalleryKit.sigmaOf(blur), 0)
        let f0 = max(focus, 0)
        return (Float(b.x0) + centerX * Float(b.width), Float(b.y0) + centerY * Float(b.height), sinf(r), cosf(r), ss, smax, f0, f0 + max(transition, 1e-3))
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let g = geometry(ctx.bounds)
        return GalleryKit.variableBlur(src, out, ctx, g.smax, trim: true) { x, y in
            let d = abs((x - g.cx) * g.nx + (y - g.cy) * g.ny) / g.ss
            return g.smax * smoothstep(g.f0, g.f1, d)
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let g = geometry(pass.ctx.bounds)
        let sp = GalleryKit.SigmaParams(kind: GalleryKit.SigmaKind.tiltShift.rawValue, count: 0, smax: g.smax, ss: g.ss,
                                        center: SIMD2(g.cx, g.cy), normal: SIMD2(g.nx, g.ny), f0: g.f0, f1: g.f1)
        try GalleryKit.encodeVariableBlur(pass, smax: g.smax, sigma: sp, pins: nil)
    }
}

/// Filter › Blur Gallery › Iris Blur: everything outside each pin's (super)ellipse is blurred; the
/// sharp core is `feather` of the ellipse; sharpness from any pin wins.
public struct IrisBlur: Filter, Hashable {
    public var pins: [IrisPin]
    public init(pins: [IrisPin] = [IrisPin()]) { self.pins = pins }
    public var label: String { "Iris Blur" }
    var smax: Float { pins.map { GalleryKit.sigmaOf($0.blur) }.reduce(0, max) }
    public func halo(bounds: PixelRect) -> Halo { .reach(GalleryKit.reach(pins.map(\.blur).reduce(0, max))) }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        if pins.isEmpty || smax < 0.3 { return src.crop(out) }
        let prepared = pins.map { GalleryKit.PreparedIris($0, ctx.bounds) }
        return GalleryKit.variableBlur(src, out, ctx, smax, trim: true) { x, y in
            prepared.map { $0.sigma(x, y) }.reduce(Float.greatestFiniteMagnitude, min)
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        if pins.isEmpty || smax < 0.3 { try pass.dispatchOut("pca_copy", params: NoParams()); return }
        let prepared = pins.map { GalleryKit.PreparedIris($0, pass.ctx.bounds) }
        let sp = GalleryKit.SigmaParams(kind: GalleryKit.SigmaKind.iris.rawValue, count: Int32(prepared.count), smax: smax, ss: 0,
                                        center: .zero, normal: .zero, f0: 0, f1: 0)
        try GalleryKit.encodeVariableBlur(pass, smax: smax, sigma: sp, pins: try pass.buffer(prepared))
    }
}

/// Filter › Blur Gallery › Field Blur: blur amounts at pins, interpolated by inverse squared
/// distance.
public struct FieldBlur: Filter, Hashable {
    public var pins: [FieldPin]
    public init(pins: [FieldPin] = [FieldPin()]) { self.pins = pins }
    public var label: String { "Field Blur" }
    var smax: Float { pins.map { GalleryKit.sigmaOf($0.blur) }.reduce(0, max) }
    public func halo(bounds: PixelRect) -> Halo { .reach(GalleryKit.reach(pins.map(\.blur).reduce(0, max))) }

    func points(_ b: PixelRect) -> [SIMD4<Float>] {
        pins.map { SIMD4(Float(b.x0) + $0.x * Float(b.width), Float(b.y0) + $0.y * Float(b.height), GalleryKit.sigmaOf($0.blur), 0) }
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        if pins.isEmpty { return src.crop(out) }
        let pts = points(ctx.bounds)
        return GalleryKit.variableBlur(src, out, ctx, smax, trim: false) { x, y in
            var ws: Float = 0, s: Float = 0
            for p in pts {
                let w = 1 / ((x - p.x) * (x - p.x) + (y - p.y) * (y - p.y) + 1)
                ws += w
                s += w * p.z
            }
            return s / ws
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        if pins.isEmpty { try pass.dispatchOut("pca_copy", params: NoParams()); return }
        let pts = points(pass.ctx.bounds)
        let sp = GalleryKit.SigmaParams(kind: GalleryKit.SigmaKind.field.rawValue, count: Int32(pts.count), smax: smax, ss: 0,
                                        center: .zero, normal: .zero, f0: 0, f1: 0)
        try GalleryKit.encodeVariableBlur(pass, smax: smax, sigma: sp, pins: try pass.buffer(pts))
    }
}

/// Filter › Blur Gallery › Spin Blur: content inside each ellipse is blurred along arcs about its
/// centre (`blurAngle` degrees), feathered at the rim; the first pin containing a pixel wins.
public struct SpinBlur: Filter, Hashable {
    public var pins: [SpinPin]
    public init(pins: [SpinPin] = [SpinPin()]) { self.pins = pins }
    public var label: String { "Spin Blur" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    /// Per pin: (sin, cos) of every sample angle for 2…64 samples (photocraft spin `Plan`).
    static func rotations(_ p: SpinPin) -> [SIMD2<Float>] {
        let theta = PCAMath.radians(clampf(p.blurAngle, 0, 360))
        var t: [SIMD2<Float>] = []
        t.reserveCapacity(2079)
        for count in 2...64 {
            for j in 0..<count {
                let phi = theta * (Float(j) / Float(count - 1) - 0.5)
                t.append(SIMD2(sinf(phi), cosf(phi)))
            }
        }
        return t
    }
    @inline(__always) static func rotationStart(_ count: Int) -> Int { count * (count - 1) / 2 - 1 }

    /// Pin geometry shared by both paths.
    struct Geo: BitwiseCopyable {
        var cx: Float, cy: Float, rxd: Float, ryd: Float     // centre; normalising radii (max 1e-3)·ss
        var sa: Float, ca: Float, rx: Float, ry: Float       // rotation; raw radii (fractions)
        var rmax: Float, theta: Float, ss: Float, pad: Float = 0
    }

    static func geometry(_ p: SpinPin, _ b: PixelRect) -> Geo {
        let ss = GalleryKit.shortSide(b)
        let angle = p.angle.isFinite ? p.angle : 0
        let r = PCAMath.radians(angle)
        return Geo(cx: Float(b.x0) + p.x * Float(b.width), cy: Float(b.y0) + p.y * Float(b.height),
                   rxd: max(p.radiusX, 1e-3) * ss, ryd: max(p.radiusY, 1e-3) * ss, sa: sinf(r), ca: cosf(r),
                   rx: p.radiusX, ry: p.radiusY, rmax: max(p.radiusX, p.radiusY), theta: PCAMath.radians(clampf(p.blurAngle, 0, 360)), ss: ss)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        var res = src.crop(out)
        let clip = ctx.bounds.intersect(src.rect)
        if clip.isEmpty || pins.isEmpty { return res }
        let geos = pins.map { Self.geometry($0, ctx.bounds) }
        let tables = pins.map { Self.rotations($0) }
        res.data.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelChunks(out.height, minChunk: 2) { rows in
                var acc = [Float](repeating: 0, count: n)
                for oy in rows {
                    for ox in 0..<out.width {
                        let fx = Float(out.x0) + Float(ox) + 0.5, fy = Float(out.y0) + Float(oy) + 0.5
                        let b = (oy * out.width + ox) * n
                        for (pi, g) in geos.enumerated() {
                            let dx = fx - g.cx, dy = fy - g.cy
                            let u = (dx * g.ca + dy * g.sa) / g.rxd, v = (-dx * g.sa + dy * g.ca) / g.ryd
                            var e = (u * u + v * v).squareRoot()
                            if !e.isFinite { e = .infinity }
                            if !e.isFinite || e >= 1 { continue }
                            let rpx = max(e * g.rmax * g.ss, 0)
                            let m = (rpx.isFinite && g.theta.isFinite) ? min(max(Int((g.theta * rpx / 2).rounded(.up)), 2), 64) : 2
                            let start = Self.rotationStart(m)
                            for c in 0..<n { acc[c] = 0 }
                            for j in 0..<m {
                                let t = tables[pi][start + j]
                                let ru = u * t.y - v * t.x, rv = u * t.x + v * t.y
                                let lu = ru * g.rx * g.ss, lv = rv * g.ry * g.ss
                                FxUtil.addSamplePremul(src, g.cx + lu * g.ca - lv * g.sa, g.cy + lu * g.sa + lv * g.ca, clip, ctx.alpha, &acc)
                            }
                            for c in 0..<n { acc[c] /= Float(m) }
                            FxUtil.unpremulPx(&acc, ctx.alpha)
                            let k = 1 - smoothstep(0.85, 1, e)
                            for c in 0..<n { rs.value[b + c] += (acc[c] - rs.value[b + c]) * k }
                            break
                        }
                    }
                }
            }
        }
        return res
    }

    struct Params: BitwiseCopyable { var clipOrigin: SIMD2<Int32>; var clipSize: SIMD2<Int32>; var count: Int32; var pad0: Int32 = 0; var pad1: Int32 = 0; var pad2: Int32 = 0 }
    public func encodeGPU(_ pass: GPUPass) throws {
        let clip = pass.ctx.bounds.intersect(pass.srcRect)
        if clip.isEmpty || pins.isEmpty { try pass.dispatchOut("pca_copy", params: NoParams()); return }
        let geos = pins.map { Self.geometry($0, pass.ctx.bounds) }
        let tables = pins.flatMap { Self.rotations($0) }
        let p = Params(clipOrigin: SIMD2(clip.x0, clip.y0), clipSize: SIMD2(Int32(clip.width), Int32(clip.height)), count: Int32(geos.count))
        try pass.dispatchOut("pca_spin_blur", params: p, buffers: [try pass.buffer(geos), try pass.buffer(tables)])
    }
}

/// Filter › Blur Gallery › Path Blur: motion blur whose direction follows the nearest paths
/// (inverse-distance weighted tangents) and whose length is the path speed, optionally tapering.
public struct PathBlur: Filter, Hashable {
    public var paths: [BlurPath]
    public init(paths: [BlurPath] = [BlurPath()]) { self.paths = paths }
    public var label: String { "Path Blur" }
    public func halo(bounds: PixelRect) -> Halo { .reach(paths.map { abs($0.speed) }.reduce(0, max) / 2 + 1) }

    /// Segments in document space: (a, b, path speed·taper data, t0, t1).
    struct Segment: BitwiseCopyable {
        var ax: Float, ay: Float, bx: Float, by: Float
        var speed: Float, taper: Float, t0: Float, t1: Float
    }

    func segments(_ b: PixelRect) -> [Segment] {
        let bw = Float(b.width), bh = Float(b.height)
        var segs: [Segment] = []
        for p in paths {
            let pts = p.points.map { (Float(b.x0) + $0.x * bw, Float(b.y0) + $0.y * bh) }
            var total: Float = 0
            if pts.count >= 2 { for i in 1..<pts.count { total += hypotf(pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1) } }
            total = max(total, 1e-3)
            var run: Float = 0
            if pts.count >= 2 {
                for i in 1..<pts.count {
                    let l = hypotf(pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1)
                    segs.append(Segment(ax: pts[i - 1].0, ay: pts[i - 1].1, bx: pts[i].0, by: pts[i].1, speed: abs(p.speed),
                                        taper: clampf(p.taper, 0, 100) / 100, t0: run / total, t1: (run + l) / total))
                    run += l
                }
            }
        }
        return segs
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        let segs = segments(ctx.bounds)
        var res = src.crop(out)
        let clip = ctx.bounds.intersect(src.rect)
        if segs.isEmpty || clip.isEmpty { return res }
        res.data.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelChunks(out.height, minChunk: 2) { rows in
                var acc = [Float](repeating: 0, count: n)
                for oy in rows {
                    for ox in 0..<out.width {
                        let fx = Float(out.x0) + Float(ox) + 0.5, fy = Float(out.y0) + Float(oy) + 0.5
                        var dx: Float = 0, dy: Float = 0, len: Float = 0, ws: Float = 0
                        for s in segs {
                            let sx = s.bx - s.ax, sy = s.by - s.ay
                            let l2 = max(sx * sx + sy * sy, 1e-6)
                            let t = clampf(((fx - s.ax) * sx + (fy - s.ay) * sy) / l2, 0, 1)
                            let ex = fx - s.ax - sx * t, ey = fy - s.ay - sy * t
                            let d2 = ex * ex + ey * ey
                            let w = 1 / (d2 + 1)
                            let l = l2.squareRoot()
                            let along = s.t0 + (s.t1 - s.t0) * t
                            dx += w * sx / l
                            dy += w * sy / l
                            len += w * s.speed * (1 - s.taper * along)
                            ws += w
                        }
                        let m = (dx * dx + dy * dy).squareRoot()
                        let ln = len / ws
                        if m < 1e-6 || ln < 0.5 { continue }
                        let ux = dx / m, uy = dy / m
                        let steps = min(max(Int((ln / 1.5).rounded(.up)) + 1, 2), 64)
                        for c in 0..<n { acc[c] = 0 }
                        for j in 0..<steps {
                            let o = ln * (Float(j) / Float(steps - 1) - 0.5)
                            FxUtil.addSamplePremul(src, fx + ux * o, fy + uy * o, clip, ctx.alpha, &acc)
                        }
                        for c in 0..<n { acc[c] /= Float(steps) }
                        FxUtil.unpremulPx(&acc, ctx.alpha)
                        let b = (oy * out.width + ox) * n
                        for c in 0..<n { rs.value[b + c] = acc[c] }
                    }
                }
            }
        }
        return res
    }

    struct Params: BitwiseCopyable { var clipOrigin: SIMD2<Int32>; var clipSize: SIMD2<Int32>; var count: Int32; var pad0: Int32 = 0; var pad1: Int32 = 0; var pad2: Int32 = 0 }
    public func encodeGPU(_ pass: GPUPass) throws {
        let segs = segments(pass.ctx.bounds)
        let clip = pass.ctx.bounds.intersect(pass.srcRect)
        if segs.isEmpty || clip.isEmpty { try pass.dispatchOut("pca_copy", params: NoParams()); return }
        let p = Params(clipOrigin: SIMD2(clip.x0, clip.y0), clipSize: SIMD2(Int32(clip.width), Int32(clip.height)), count: Int32(segs.count))
        try pass.dispatchOut("pca_path_blur", params: p, buffers: [try pass.buffer(segs)])
    }
}
