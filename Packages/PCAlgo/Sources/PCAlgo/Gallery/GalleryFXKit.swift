// Port of photocraft-algo (crates/algo/src/artistic_fx.rs: `Win`, helpers, `effect_reach`, `reach`, `run`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Filter Gallery's working window and shared helpers. Every effect runs on an sRGB working
// copy of the tile's source window (straight colour; the source alpha is kept) and may read up
// to `effectReach` pixels around each output pixel, so a stack reads the sum of their reaches.
// Noise, strokes and textures are functions of document coordinates, so results do not depend
// on the tiling. Blurs are FxUtil's buffer blurs (f64 running sums, edges clamped to the window).

import Foundation
import PCFoundation

enum GalleryFXKit {
    typealias Px = SIMD3<Float>

    /// The working window: sRGB colour (3 floats) of every pixel of `r`.
    struct Win {
        var r: PixelRect
        var w: Int
        var h: Int
        var c: [Float]

        @inline(__always) func xy(_ i: Int) -> (Int32, Int32) { (r.x0 + Int32(i % w), r.y0 + Int32(i / w)) }
        @inline(__always) func px(_ i: Int) -> Px { Px(c[i * 3], c[i * 3 + 1], c[i * 3 + 2]) }
        var count: Int { w * h }

        func lum() -> [Float] {
            var l = [Float](repeating: 0, count: count)
            c.withUnsafeBufferPointer { cb in
                l.withUnsafeMutableBufferPointer { lb in
                    let ls = UnsafeSendable(lb)
                    parallelChunks(count, minChunk: 1 << 14) { rg in
                        for i in rg { ls.value[i] = GalleryFXKit.lum(Px(cb[i * 3], cb[i * 3 + 1], cb[i * 3 + 2])) }
                    }
                }
            }
            return l
        }

        /// Bilinear sample at document coordinates (pixel centres at .5), clamped to the window.
        @inline(__always)
        func sample(_ x: Float, _ y: Float) -> Px {
            let fx = clampf(x - 0.5 - Float(r.x0), 0, Float(w - 1)), fy = clampf(y - 0.5 - Float(r.y0), 0, Float(h - 1))
            let x0 = PCAMath.usize(fx.rounded(.down)), y0 = PCAMath.usize(fy.rounded(.down))
            let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
            let ax = fx - Float(x0), ay = fy - Float(y0)
            @inline(__always) func g(_ xx: Int, _ yy: Int) -> Px { px(yy * w + xx) }
            let top = mix(g(x0, y0), g(x1, y0), ax), bot = mix(g(x0, y1), g(x1, y1), ax)
            return mix(top, bot, ay)
        }

        /// The pixel nearest to document (x, y), clamped to the window.
        @inline(__always)
        func at(_ x: Int32, _ y: Int32) -> Px {
            let xx = Int(min(max(Int64(x) - Int64(r.x0), 0), Int64(w - 1))), yy = Int(min(max(Int64(y) - Int64(r.y0), 0), Int64(h - 1)))
            return px(yy * w + xx)
        }

        /// Replaces every pixel by `f(i, x, y, colour)`, in parallel (each pixel writes only itself).
        mutating func map(_ f: (Int, Int32, Int32, Px) -> Px) {
            let (w, r, n) = (self.w, self.r, count)
            c.withUnsafeMutableBufferPointer { cb in
                let cs = UnsafeSendable(cb)
                parallelChunks(n, minChunk: 2048) { rg in
                    for i in rg {
                        let p = Px(cs.value[i * 3], cs.value[i * 3 + 1], cs.value[i * 3 + 2])
                        let q = f(i, r.x0 + Int32(i % w), r.y0 + Int32(i / w), p)
                        cs.value[i * 3] = q.x; cs.value[i * 3 + 1] = q.y; cs.value[i * 3 + 2] = q.z
                    }
                }
            }
        }
    }

    // MARK: Small maths (photocraft artistic_fx free functions)

    @inline(__always) static func lum(_ p: Px) -> Float { 0.299 * p.x + 0.587 * p.y + 0.114 * p.z }
    @inline(__always) static func mix(_ a: Px, _ b: Px, _ t: Float) -> Px { a + (b - a) * t }
    @inline(__always) static func map(_ p: Px, _ f: (Float) -> Float) -> Px { Px(f(p.x), f(p.y), f(p.z)) }
    @inline(__always) static func grey(_ v: Float) -> Px { Px(v, v, v) }
    @inline(__always) static func rgb(_ c: SIMD4<Float>) -> Px { Px(c.x, c.y, c.z) }
    @inline(__always) static func clamp01(_ v: Float) -> Float { clampf(v, 0, 1) }
    @inline(__always) static func fmax(_ a: Float, _ b: Float) -> Float { Float.maximum(a, b) }
    @inline(__always) static func fmin(_ a: Float, _ b: Float) -> Float { Float.minimum(a, b) }

    /// Hermite step from `e0` to `e1`; `e0 > e1` gives the falling step (the gallery's own
    /// `smoothstep`, not fxutil's).
    @inline(__always)
    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        if abs(e1 - e0) < 1e-9 { return x >= e1 ? 1 : 0 }
        let t = clampf((x - e0) / (e1 - e0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    static func posterize(_ v: Float, _ levels: Float) -> Float {
        let l = fmax(levels - 1, 1)
        return (clamp01(v) * l).rounded(.toNearestOrAwayFromZero) / l
    }

    @inline(__always)
    static func saturate(_ p: Px, _ k: Float) -> Px {
        let l = lum(p)
        return map(p) { l + ($0 - l) * k }
    }

    /// Rust `f32::fract` (`x − trunc(x)`; negative for negative x).
    @inline(__always) static func fract(_ x: Float) -> Float { x - x.rounded(.towardZero) }

    static func normalize3(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let l = fmax((v.x * v.x + v.y * v.y + v.z * v.z).squareRoot(), 1e-9)
        return SIMD3(v.x / l, v.y / l, v.z / l)
    }

    // MARK: Blurs and gradients

    /// Pixels a three-box Gaussian of `sigma` reads (photocraft `gs`).
    static func gs(_ sigma: Float) -> Int32 {
        sigma < 0.3 ? 0 : Int32(FxUtil.gaussBoxRadii(sigma).reduce(0, +)) + 1
    }

    static func blur1(_ p: inout [Float], _ w: Int, _ h: Int, _ sigma: Float) { FxUtil.gaussBlurN(&p, w, h, 1, sigma) }
    static func blur3(_ c: inout [Float], _ w: Int, _ h: Int, _ sigma: Float) { FxUtil.gaussBlurN(&c, w, h, 3, sigma) }

    /// Sobel gradient / 8 of a plane, edges clamped (photocraft `sobel`).
    static func sobel(_ p: [Float], _ w: Int, _ h: Int) -> ([Float], [Float]) {
        var gx = [Float](repeating: 0, count: w * h), gy = gx
        p.withUnsafeBufferPointer { pb in
            gx.withUnsafeMutableBufferPointer { xb in
                gy.withUnsafeMutableBufferPointer { yb in
                    let xs = UnsafeSendable(xb), ys = UnsafeSendable(yb)
                    parallelFor(h) { y in
                        @inline(__always) func at(_ x: Int, _ yy: Int) -> Float { pb[min(max(yy, 0), h - 1) * w + min(max(x, 0), w - 1)] }
                        for x in 0..<w {
                            xs.value[y * w + x] = ((at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2 * at(x - 1, y) + at(x - 1, y + 1))) / 8
                            ys.value[y * w + x] = ((at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2 * at(x, y - 1) + at(x + 1, y - 1))) / 8
                        }
                    }
                }
            }
        }
        return (gx, gy)
    }

    static func gradMag(_ p: [Float], _ w: Int, _ h: Int) -> [Float] {
        let (gx, gy) = sobel(p, w, h)
        return zip(gx, gy).map { ($0 * $0 + $1 * $1).squareRoot() }
    }

    /// The pixel indices of every line along `d` through a `w × h` buffer, each from its start
    /// (photocraft `line_blur`'s line walk).
    static func lines(_ w: Int, _ h: Int, _ d: (Int32, Int32)) -> [(Int32, Int32, Int)] {
        let (wi, hi) = (Int32(w), Int32(h))
        @inline(__always) func inside(_ x: Int32, _ y: Int32) -> Bool { x >= 0 && y >= 0 && x < wi && y < hi }
        var out: [(Int32, Int32, Int)] = []
        for sy in 0..<hi {
            for sx in 0..<wi where !inside(sx - d.0, sy - d.1) {
                var (x, y, m) = (sx, sy, 0)
                while inside(x, y) { m += 1; x += d.0; y += d.1 }
                out.append((sx, sy, m))
            }
        }
        return out
    }

    /// Running-mean blur of radius `r` steps along `d` ((1,0), (0,1), (1,1) or (1,−1)) of an
    /// interleaved `n`-channel buffer, f64 sums, ends clamped per line (photocraft `line_blur`).
    static func lineBlur(_ buf: inout [Float], _ n: Int, _ w: Int, _ h: Int, _ d: (Int32, Int32), _ r: Int) {
        if r == 0 || w == 0 || h == 0 { return }
        let ls = lines(w, h, d)
        let norm = 1 / Double(2 * r + 1)
        buf.withUnsafeMutableBufferPointer { bb in
            let b = UnsafeSendable(bb)
            parallelFor(ls.count) { li in
                let (sx, sy, m) = ls[li]
                var vals = [Double](repeating: 0, count: m)
                for c in 0..<n {
                    for k in 0..<m { vals[k] = Double(b.value[(Int(sy + Int32(k) * d.1) * w + Int(sx + Int32(k) * d.0)) * n + c]) }
                    @inline(__always) func at(_ k: Int) -> Double { vals[min(max(k, 0), m - 1)] }
                    var acc = 0.0
                    for k in -r...r { acc += at(k) }
                    for k in 0..<m {
                        b.value[(Int(sy + Int32(k) * d.1) * w + Int(sx + Int32(k) * d.0)) * n + c] = Float(acc * norm)
                        acc += at(k + r + 1) - at(k - r)
                    }
                }
            }
        }
    }

    static func direction(_ name: String) -> (Int32, Int32) {
        switch name {
        case "horizontal": (1, 0)
        case "vertical": (0, 1)
        case "leftDiagonal": (1, 1)
        default: (1, -1)  // rightDiagonal: bottom-left to top-right
        }
    }

    /// Kuwahara smoothing (the flattest of four quadrant means) with box means.
    static func kuwahara(_ win: inout Win, _ r: Int) {
        let h2 = max((r + 1) / 2, 1)
        let (w, h) = (win.w, win.h)
        var m = [Float](repeating: 0, count: w * h * 5)
        for i in 0..<(w * h) {
            let p = win.px(i), l = lum(p)
            m[i * 5] = p.x; m[i * 5 + 1] = p.y; m[i * 5 + 2] = p.z; m[i * 5 + 3] = l; m[i * 5 + 4] = l * l
        }
        FxUtil.boxBlurN(&m, w, h, 5, h2)
        let o = h2
        m.withUnsafeBufferPointer { mb in
            win.map { i, _, _, _ in
                let x = i % w, y = i / w
                var best = Float.greatestFiniteMagnitude
                var col = Px(0, 0, 0)
                for (dx, dy) in [(-o, -o), (o, -o), (-o, o), (o, o)] {
                    let q = (min(max(y + dy, 0), h - 1) * w + min(max(x + dx, 0), w - 1)) * 5
                    let v = mb[q + 4] - mb[q + 3] * mb[q + 3]
                    if v < best { best = v; col = Px(mb[q], mb[q + 1], mb[q + 2]) }
                }
                return col
            }
        }
    }

    static func kuwaharaReach(_ r: Int) -> Int32 { 2 * Int32(max((r + 1) / 2, 1)) + 1 }

    static func unsharp(_ win: inout Win, _ sigma: Float, _ amount: Float) {
        if amount <= 0 { return }
        var b = win.c
        blur3(&b, win.w, win.h, sigma)
        b.withUnsafeBufferPointer { bb in
            win.map { i, _, _, p in Px(p.x + (p.x - bb[i * 3]) * amount, p.y + (p.y - bb[i * 3 + 1]) * amount, p.z + (p.z - bb[i * 3 + 2]) * amount) }
        }
    }

    // MARK: Noise, strokes, textures

    /// Smooth value noise (0–1) on a unit lattice.
    @inline(__always)
    static func vnoise(_ x: Float, _ y: Float, _ seed: UInt32) -> Float {
        let ix = PCAMath.i32(x.rounded(.down)), iy = PCAMath.i32(y.rounded(.down))
        let tx = x - Float(ix), ty = y - Float(iy)
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        @inline(__always) func h(_ a: Int32, _ b: Int32) -> Float { hash01(a, b, 0, seed) }
        let top = h(ix, iy) + (h(ix &+ 1, iy) - h(ix, iy)) * sx
        let bot = h(ix, iy &+ 1) + (h(ix &+ 1, iy &+ 1) - h(ix, iy &+ 1)) * sx
        return top + (bot - top) * sy
    }

    /// Three-octave value noise (0–1).
    @inline(__always)
    static func fbm(_ x: Float, _ y: Float, _ seed: UInt32) -> Float {
        (vnoise(x, y, seed) * 0.57 + vnoise(x * 2.03, y * 2.03, seed ^ 0x51) * 0.29 + vnoise(x * 4.1, y * 4.1, seed ^ 0xa3) * 0.14) / 1
    }

    @inline(__always)
    static func unit(_ d: (Int32, Int32)) -> (Float, Float) {
        let dx = Float(d.0), dy = Float(d.1)
        let l = fmax((dx * dx + dy * dy).squareRoot(), 1e-6)
        return (dx / l, dy / l)
    }

    /// Stroke texture: value noise stretched `len` px along `d` and `wid` px across.
    @inline(__always)
    static func strokes(_ x: Int32, _ y: Int32, _ d: (Int32, Int32), _ len: Float, _ wid: Float, _ seed: UInt32) -> Float {
        let (ux, uy) = unit(d)
        let fx = Float(x), fy = Float(y)
        let u = fx * ux + fy * uy
        let v = -fx * uy + fy * ux
        return vnoise(u / fmax(len, 0.5), v / fmax(wid, 0.3), seed)
    }

    /// Discrete strokes `len` px long and `wid` px wide along `d`, each coloured from `src` at its
    /// middle, staggered per lane; also where the pixel lies along its stroke (photocraft `paint_stroke`).
    @inline(__always)
    static func paintStroke(_ src: Win, _ x: Int32, _ y: Int32, _ d: (Int32, Int32), _ len: Float, _ wid: Float, _ seed: UInt32) -> (Px, Float) {
        let (ux, uy) = unit(d)
        let (len, wid) = (fmax(len, 1), fmax(wid, 0.5))
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        let u = fx * ux + fy * uy
        let v = -fx * uy + fy * ux
        let lane = PCAMath.i32((v / wid).rounded(.down))
        let off = hash01(lane, 0, 0, seed) * len
        let t = euclidMod((u + off) / len, 1)
        let du = (0.5 - t) * len
        return (src.sample(fx + du * ux, fy + du * uy), t)
    }

    /// Unit vector toward the light in image coordinates (y down).
    static func lightDir(_ name: String) -> (Float, Float) {
        let s: Float = 0.707_106_77
        switch name {
        case "bottom": return (0, 1)
        case "bottomLeft": return (-s, s)
        case "left": return (-1, 0)
        case "topLeft": return (-s, -s)
        case "topRight": return (s, -s)
        case "right": return (1, 0)
        case "bottomRight": return (s, s)
        default: return (0, -1)
        }
    }

    /// Lambert shading factor (1 = flat) of a height field with gradient (gx, gy).
    @inline(__always)
    static func shade(_ gx: Float, _ gy: Float, _ light: (Float, Float), _ k: Float) -> Float {
        let (nx, ny, nz) = (-k * gx, -k * gy, Float(1))
        let nl = (nx * nx + ny * ny + nz * nz).squareRoot()
        let (lx, ly, lz) = (light.0, light.1, Float(1))
        let ll = (lx * lx + ly * ly + lz * lz).squareRoot()
        let d = (nx * lx + ny * ly + nz * lz) / (nl * ll)
        return d / (lz / ll)
    }

    /// Procedural texture kinds (MSL `pca_gfx_texture` codes).
    static func textureCode(_ kind: String) -> Int32 {
        switch kind {
        case "brick": 0
        case "burlap": 1
        case "canvas": 2
        case "sandstone": 3
        case "blocks": 4
        case "frosted": 5
        case "tinyLens": 6
        default: 7
        }
    }

    /// Procedural textures (0–1 heights) at document coordinates; `s` scales them (1 = 100 %).
    @inline(__always)
    static func texture(_ kind: Int32, _ x: Float, _ y: Float, _ s: Float) -> Float {
        let x = x / s, y = y / s
        switch kind {
        case 0:
            let (bw, bh): (Float, Float) = (24, 12)
            let row = (y / bh).rounded(.down)
            let xo = x + (PCAMath.i32(row) % 2 == 0 ? 0 : bw / 2)
            let u = euclidMod(xo, bw), v = euclidMod(y, bh)
            let d = fmin(fmin(u, bw - u), fmin(v, bh - v))
            return smoothstep(0.6, 2.2, d) * (0.85 + 0.15 * vnoise(x / 3, y / 3, 91))
        case 1: return weave(x, y, 7, 0.35)
        case 2: return weave(x, y, 3.5, 0.18)
        case 3: return fbm(x / 7, y / 7, 93) * 0.7 + hash01(PCAMath.i32(x), PCAMath.i32(y), 0, 94) * 0.3
        case 4:
            let b: Float = 18
            let u = euclidMod(x, b) / b, v = euclidMod(y, b) / b
            return fmin(fmin(fmin(u, 1 - u), fmin(v, 1 - v)) * 4, 1)
        case 5: return fbm(x / 2.5, y / 2.5, 95)
        case 6:
            let p: Float = 12
            let u = (euclidMod(x, p) / p - 0.5) * 2, v = (euclidMod(y, p) / p - 0.5) * 2
            return fmax(1 - (u * u + v * v), 0).squareRoot()
        default: return 0.5
        }
    }

    /// Basket weave of threads `p` px wide with `noise` irregularity.
    @inline(__always)
    static func weave(_ x: Float, _ y: Float, _ p: Float, _ noise: Float) -> Float {
        let cx = PCAMath.i32((x / p).rounded(.down)), cy = PCAMath.i32((y / p).rounded(.down))
        let overH = euclidMod(cx &+ cy, 2) == 0
        let u = euclidMod(x, p) / p, v = euclidMod(y, p) / p
        // A thread is a rounded ridge across its cell.
        let ridge = overH ? sinf(v * PCAMath.pi) : sinf(u * PCAMath.pi)
        let n = vnoise(x / (p * 0.7), y / (p * 2), 97)
        return ridge * (1 - noise) + n * noise
    }

    /// Texturizer core: relief-shades the window with a procedural texture, scaled per pixel by
    /// `weight` of its colour (photocraft `texturize_by`; `texturize` is weight 1).
    static func texturize(_ win: inout Win, _ kind: String, _ scaling: Float, _ relief: Float, _ light: String, _ invert: Bool,
                          weight: ((Px) -> Float)? = nil) {
        if relief <= 0 { return }
        let s = clampf(scaling / 100, 0.5, 2)
        let l = lightDir(light)
        let k = relief / 50 * 3
        let sign: Float = invert ? -1 : 1
        let code = textureCode(kind)
        win.map { _, x, y, p in
            let fx = Float(x), fy = Float(y)
            let gx = (texture(code, fx + 1, fy, s) - texture(code, fx - 1, fy, s)) * 0.5 * sign
            let gy = (texture(code, fx, fy + 1, s) - texture(code, fx, fy - 1, s)) * 0.5 * sign
            let f = 1 + (clampf(shade(gx, gy, l, k), 0, 2) - 1) * (weight?(p) ?? 1)
            return map(p) { $0 * f }
        }
    }

    /// Closest and second-closest jittered cell points (distances and the closest point).
    @inline(__always)
    static func voronoi(_ x: Float, _ y: Float, _ cell: Float, _ seed: UInt32) -> (Float, Float, (Float, Float)) {
        let cx = PCAMath.i32((x / cell).rounded(.down)), cy = PCAMath.i32((y / cell).rounded(.down))
        var d1 = Float.greatestFiniteMagnitude, d2 = Float.greatestFiniteMagnitude, p1 = (x, y)
        for j: Int32 in -1...1 {
            for i: Int32 in -1...1 {
                let p = FxUtil.cellPoint(cx &+ i, cy &+ j, cell, seed, (0, 0))
                let d = ((p.0 - x) * (p.0 - x) + (p.1 - y) * (p.1 - y)).squareRoot()
                if d < d1 { d2 = d1; d1 = d; p1 = p } else if d < d2 { d2 = d }
            }
        }
        return (d1, d2, p1)
    }

    /// Brightens highlights (Film Grain / Smudge Stick "Highlight Area" and "Intensity").
    @inline(__always)
    static func highlights(_ p: Px, _ l: Float, _ area: Float, _ intensity: Float) -> Px {
        if area <= 0 { return p }
        let m = smoothstep(1 - area / 20 * 0.75, 1.02, l) * (1 - intensity / 10 * 0.6)
        return map(p) { $0 + (1 - $0) * m }
    }

    // MARK: Reach

    static func cutoutSigma(_ e: GalleryEffect) -> Float { 0.5 + e.get("edgeSimplicity") * (1.1 - 0.3 * e.get("edgeFidelity")) }
    static func daubsRadius(_ e: GalleryEffect) -> Int {
        let wide = ["wideSharp", "wideBlurry"].contains(e.choice("brushType"))
        let r = e.get("brushSize") / 2 * (wide ? 1.5 : 1)
        return PCAMath.usize(fmax(r, 1))
    }
    static func plasticSigma(_ e: GalleryEffect) -> Float { 0.5 + e.get("smoothness") * 0.5 + (15 - e.get("detail")) * 0.2 }
    static func watercolorRadius(_ e: GalleryEffect) -> Int { 1 + PCAMath.usize((15 - e.get("brushDetail")) / 2.5) }
    static func basreliefSigma(_ e: GalleryEffect) -> Float { 0.3 + e.get("smoothness") * 0.5 + (15 - e.get("detail")) * 0.12 }
    static func patchSize(_ e: GalleryEffect) -> Float { 3 + e.get("squareSize") * 1.5 }
    static func glassCell(_ e: GalleryEffect) -> Float { e.get("cellSize") * 1.6 + 1 }

    /// Pixels an effect reads around an output pixel (photocraft `effect_reach`).
    static func effectReach(_ e: GalleryEffect) -> Int32 {
        let g = { (k: String) in e.get(k) }
        let i32 = PCAMath.i32
        switch e.filter {
        case .coloredPencil: return 2
        case .cutout: return gs(cutoutSigma(e))
        case .dryBrush, .fresco: return kuwaharaReach(1 + PCAMath.usize(g("brushSize"))) &+ gs(1) &+ 2
        case .filmGrain, .diffuseGlow, .chalkCharcoal, .reticulation, .grain, .mosaicTiles, .texturizer: return 0
        case .roughPastels: return gs(0.6 + 1.2) &+ i32((2 + g("strokeLength")) / 2) &+ 3
        case .neonGlow: return gs(abs(g("glowSize")) * 0.6 + 0.5)
        case .paintDaubs: return kuwaharaReach(daubsRadius(e)) &+ gs(1.5) &+ 1
        case .paletteKnife: return kuwaharaReach(PCAMath.usize(fmax(g("strokeSize") / 3, 1))) &+ gs(g("softness") * 0.5)
        case .plasticWrap: return gs(plasticSigma(e)) &+ 2
        case .posterEdges: return gs(0.6 + g("edgeThickness") * 0.6) &+ 2
        case .smudgeStick: return i32(g("strokeLength") * 1.5) &+ 2
        case .sponge: return kuwaharaReach(1 + PCAMath.usize(g("brushSize")))
        case .underpainting: return gs(0.5 + g("brushSize") * 0.4)
        case .watercolor: return kuwaharaReach(watercolorRadius(e)) &+ 2
        case .accentedEdges: return gs(0.4 + g("smoothness") * 0.3) &+ gs(g("edgeWidth") * 0.5) &+ 2
        case .angledStrokes: return gs(0.8) &+ i32(fmax(g("strokeLength"), 3) / 2) &+ gs(1) &+ 3
        case .crosshatch: return i32(g("strokeLength") / 3) &+ gs(1) &+ 2
        case .darkStrokes: return 9
        case .inkOutlines: return i32(g("strokeLength") / 2) &+ 3
        case .spatter: return i32(g("sprayRadius").rounded(.up)) &+ 2
        case .sprayedStrokes: return i32(g("sprayRadius").rounded(.up)) &+ i32(g("strokeLength") / 2) &+ 3
        case .sumiE: return gs(g("strokeWidth") * 0.2) &+ i32(g("strokeWidth") / 2) &+ 2
        case .glass: return i32((g("distortion") * 2).rounded(.up)) &+ 2
        case .oceanRipple: return i32((g("rippleMagnitude") * 0.9).rounded(.up)) &+ 2
        case .basRelief: return gs(basreliefSigma(e)) &+ 2
        case .charcoal: return gs(1) &+ 2
        case .chrome: return gs(1 + g("smoothness") * 0.4) &+ 2
        case .conteCrayon: return 0
        case .graphicPen: return i32(g("strokeLength") / 2) &+ 2
        case .halftonePattern: return gs(0.5 + g("size") * 0.3)
        case .notePaper: return gs(1) &+ gs(1.2) &+ 2
        case .photocopy: return gs(1 + g("detail") * 0.5)
        case .plaster: return gs(0.5 + g("smoothness") * 0.8) &+ gs(1.5) &+ 2
        case .stamp: return gs(0.3 + g("smoothness") * 0.3)
        case .tornEdges: return gs(1)
        case .waterPaper: return 2 &* i32(g("fiberLength") / 6) &+ 2
        case .glowingEdges: return gs(0.3 + g("smoothness") * 0.25) &+ gs(g("edgeWidth") * 0.4) &+ 2
        case .craquelure: return 0
        case .patchwork: return i32(patchSize(e).rounded(.up)) &+ 2
        case .stainedGlass: return i32((glassCell(e) * 2.5).rounded(.up)) &+ 2
        }
    }

    /// Total reach of a stack of effects (photocraft `reach`), clamped non-negative.
    static func reach(_ effects: [GalleryEffect]) -> Int32 {
        max(effects.reduce(Int32(0)) { $0 &+ effectReach($1) }, 0)
    }
}
