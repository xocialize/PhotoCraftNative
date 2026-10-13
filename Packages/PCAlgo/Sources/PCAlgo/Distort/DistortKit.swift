// Port of photocraft-algo (crates/algo/src/distort.rs, image.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The inverse-mapping machinery every distortion shares: photocraft `distort::remap` (each output
// pixel centre is mapped back to a source position, which is sampled bilinearly, premultiplied,
// with an edge policy relative to the reference bounds) and `distort::centre`. The MSL twin of
// the sampler is `pca_sample` (Shaders/00_Common.metal); kernels live in Shaders/Distort*.metal.

import PCFoundation

enum DistortKit {
    /// Rust's `std::f32::consts::PI` (the nearest Float; Swift's `Float.pi` rounds toward zero,
    /// one ulp below it).
    static let pi: Float = 3.14159265358979323846
    /// Rust's `std::f32::consts::TAU`.
    static let tau: Float = 6.28318530717958647692
    /// Rust's `std::f32::consts::FRAC_PI_2`.
    static let halfPi: Float = 1.57079632679489661923

    /// Degrees → radians as Rust's `f32::to_radians` (`v * (PI / 180)`).
    @inline(__always)
    static func radians(_ deg: Float) -> Float { deg * (pi / 180) }

    /// Centre and inscribed radius of the bounds (photocraft `distort::centre`).
    static func centre(_ b: PixelRect) -> (Float, Float, Float) {
        let w = Float(b.width), h = Float(b.height)
        return (Float(b.x0) + w / 2, Float(b.y0) + h / 2, min(w, h) / 2)
    }

    /// MSL `PCA_EDGE_*` code of an edge policy.
    static func gpuEdge(_ e: EdgeMode) -> UInt32 {
        switch e {
        case .transparent: 0
        case .repeatEdge: 1
        case .wrap: 2
        }
    }

    /// Rust's saturating `f32 as i32` for a floored sample coordinate (NaN → 0). Coordinates are
    /// kept within ±1e9 so the +1 taps and the wrap arithmetic cannot overflow (no Swift trap).
    @inline(__always)
    static func floorToInt(_ v: Float) -> Int32 {
        if v.isNaN { return 0 }
        return Int32(min(max(v, -1e9), 1e9))
    }

    /// Sample offset of `(x, y)` under `edge` relative to `area` in an image covering `r` with `n`
    /// channels, or -1 when the sample reads 0 (photocraft `Image::get_edge` + `get`).
    @inline(__always)
    static func edgeIndex(_ x: Int32, _ y: Int32, _ r: PixelRect, _ n: Int, _ edge: EdgeMode, _ area: PixelRect) -> Int {
        if area.isEmpty { return -1 }
        var sx = x, sy = y
        if !area.contains(x: x, y: y) {
            switch edge {
            case .transparent: return -1
            case .repeatEdge:
                sx = min(max(x, area.x0), area.x1 - 1)
                sy = min(max(y, area.y0), area.y1 - 1)
            case .wrap:
                let w = Int32(max(area.width, 1)), h = Int32(max(area.height, 1))
                sx = area.x0 + euclidMod(x - area.x0, w)
                sy = area.y0 + euclidMod(y - area.y0, h)
            }
        }
        if !r.contains(x: sx, y: sy) { return -1 }
        return (Int(sy - r.y0) * r.width + Int(sx - r.x0)) * n
    }

    /// photocraft `Image::sample` into `out` (straight colour, alpha last): bilinear over the
    /// premultiplied pixels around `(x, y)` (pixel centres at .5), taps in the order
    /// (0,0) (1,0) (0,1) (1,1), zero-weight taps skipped — the same sums as `pca_sample`.
    @inline(__always)
    static func sample(_ s: UnsafeBufferPointer<Float>, _ r: PixelRect, _ n: Int, _ x: Float, _ y: Float,
                       _ edge: EdgeMode, _ area: PixelRect, _ alpha: Bool, _ out: UnsafeMutablePointer<Float>) {
        let fx = x - 0.5, fy = y - 0.5
        let flx = fx.rounded(.down), fly = fy.rounded(.down)
        let ax = fx - flx, ay = fy - fly
        let x0 = floorToInt(flx), y0 = floorToInt(fly)
        for c in 0..<n { out[c] = 0 }
        let nc = alpha ? n - 1 : n
        var accA: Float = 0
        @inline(__always) func tap(_ dx: Int32, _ dy: Int32, _ w: Float) {
            if w <= 0 { return }
            let i = edgeIndex(x0 + dx, y0 + dy, r, n, edge, area)
            let a: Float = alpha ? (i < 0 ? 0 : s[i + n - 1]) : 1
            for c in 0..<nc { out[c] += (i < 0 ? 0 : s[i + c]) * a * w }
            accA += a * w
        }
        tap(0, 0, (1 - ax) * (1 - ay))
        tap(1, 0, ax * (1 - ay))
        tap(0, 1, (1 - ax) * ay)
        tap(1, 1, ax * ay)
        if alpha {
            if accA > 0 { for c in 0..<nc { out[c] /= accA } }
            out[n - 1] = accA
        }
    }

    /// photocraft `distort::remap`: every output pixel centre `(x + .5, y + .5)` mapped through
    /// `f` and sampled from `src` with `edge` relative to the bounds. Rows run in parallel.
    static func remap(_ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext, _ edge: EdgeMode,
                      _ f: (Float, Float) -> (Float, Float)) -> FloatImage {
        let n = src.channels
        var res = FloatImage(rect: out, channels: n)
        if out.isEmpty || n == 0 { return res }
        let w = out.width, sr = src.rect, area = ctx.bounds, alpha = ctx.alpha
        src.data.withUnsafeBufferPointer { s in
            res.data.withUnsafeMutableBufferPointer { d in
                let dp = UnsafeSendable(d.baseAddress!)
                parallelChunks(out.height, minChunk: 2) { rows in
                    for row in rows {
                        let y = out.y0 + Int32(row)
                        for col in 0..<w {
                            let x = out.x0 + Int32(col)
                            let (sx, sy) = f(Float(x) + 0.5, Float(y) + 0.5)
                            sample(s, sr, n, sx, sy, edge, area, alpha, dp.value + (row * w + col) * n)
                        }
                    }
                }
            }
        }
        return res
    }
}
