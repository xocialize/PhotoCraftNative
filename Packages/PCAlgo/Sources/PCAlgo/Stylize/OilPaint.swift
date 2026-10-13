// Port of photocraft-algo (crates/algo/src/oil.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Stylize › Oil Paint: flow-guided smoothing plus a lit bristle relief. The structure
// tensor of the (cleaned) colour mean gives a stroke direction field (Brox et al.), a line
// integral convolution (Cabral & Leedom 1993) smears colour along it (as in Kyprianidis &
// Döllner 2008), white noise convolved along the same field makes bristle streaks, and the
// smoothed brightness plus the streaks form a height map shaded by a directional light.
//
// Like photocraft, every stage works on the whole source window (blurs clamp at its edges).

import Foundation
import Metal
import PCFoundation

/// Filter › Stylize › Oil Paint, in Photoshop's units: stylization 0.1–10, cleanliness 0–10,
/// scale 0.1–10, bristle detail 0–10, lighting angle degrees, shine 0–10.
public struct OilPaint: Filter, Hashable {
    public var stylization: Float
    public var cleanliness: Float
    public var scale: Float
    public var bristleDetail: Float
    public var lighting: Bool
    public var angle: Float
    public var shine: Float
    public init(stylization: Float = 4, cleanliness: Float = 5, scale: Float = 1, bristleDetail: Float = 5,
                lighting: Bool = true, angle: Float = -60, shine: Float = 1) {
        self.stylization = stylization; self.cleanliness = cleanliness; self.scale = scale
        self.bristleDetail = bristleDetail; self.lighting = lighting; self.angle = angle; self.shine = shine
    }
    public var label: String { "Oil Paint" }

    static func strokeLen(_ stylization: Float) -> Float { 1.5 + clampf(stylization, 0.1, 10) * 2 }
    static func tensorSigma(_ scale: Float) -> Float { 0.8 + clampf(scale, 0.1, 10) * 0.6 }
    /// Pixels read beyond an output tile (photocraft `oil::reach`).
    static func reach(_ stylization: Float, _ scale: Float) -> Float {
        strokeLen(stylization) + 3 * tensorSigma(scale) + 3 * 2.5 + 4
    }
    public func halo(bounds: PixelRect) -> Halo { StylizeKit.reach(Self.reach(stylization, scale)) }

    /// The tensor is built from the mean of all colour channels: any model, one plane.
    public var gpuChannels: GPUChannels { .joint }
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool {
        StylizeKit.onePlane(ctx, channels: channels) && ctx.colorChannels(channels) > 0
    }

    /// Light and half vectors and the flat specular term (photocraft step 6 constants).
    struct Light {
        var light: SIMD3<Float>
        var half: SIMD3<Float>
        var flatSpec: Float
    }

    var light: Light {
        let r = StylizeKit.radians(angle)
        let (ls, lc) = (sinf(r), cosf(r))
        let elev = StylizeKit.radians(45)
        let l = SIMD3<Float>(lc * cosf(elev), -ls * cosf(elev), sinf(elev))
        let v = SIMD3<Float>(l.x, l.y, l.z + 1)
        let m = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        let h = SIMD3<Float>(v.x / m, v.y / m, v.z / m)
        return Light(light: l, half: h, flatSpec: powf(h.z, 40))
    }

    /// LIC step length and count.
    var lic: (Float, Int32) {
        let len = Self.strokeLen(stylization)
        let h = StylizeKit.fmax(len / 10, 1)
        return (h, StylizeKit.i32((len / h).rounded(.up)))
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        let win = src.rect
        let ww = win.width, wh = win.height
        let alpha = ctx.alpha
        let cc = ctx.colorChannels(n)
        var res = FloatImage(rect: out, channels: n)
        if out.isEmpty || n == 0 || cc == 0 || ww == 0 || wh == 0 { return src.crop(out) }
        // 1. Premultiplied colour, cleaned (pre-smoothed) by `cleanliness`.
        var p = FxUtil.premulWindow(src, win, alpha)
        FxUtil.gaussBlurN(&p, ww, wh, n, clampf(cleanliness, 0, 10) * 0.25)
        // 2. Intensity for the structure tensor (the channel mean works in every model).
        var lum = [Float](repeating: 0, count: ww * wh)
        p.withUnsafeBufferPointer { pb in
            for i in 0..<(ww * wh) {
                var s: Float = 0
                for c in 0..<cc { s += pb[i * n + c] }
                lum[i] = s / Float(cc)
            }
        }
        // 3. Smoothed structure tensor (E, F, G).
        var efg = [Float](repeating: 0, count: ww * wh * 3)
        if ww >= 3 && wh >= 3 {
            lum.withUnsafeBufferPointer { l in
                efg.withUnsafeMutableBufferPointer { eb in
                    let e = UnsafeSendable(eb)
                    parallelFor(wh - 2) { yi in
                        let y = yi + 1
                        for x in 1..<(ww - 1) {
                            @inline(__always) func L(_ dx: Int, _ dy: Int) -> Float { l[(y + dy) * ww + x + dx] }
                            let gx = (L(1, -1) + 2 * L(1, 0) + L(1, 1)) - (L(-1, -1) + 2 * L(-1, 0) + L(-1, 1))
                            let gy = (L(-1, 1) + 2 * L(0, 1) + L(1, 1)) - (L(-1, -1) + 2 * L(0, -1) + L(1, -1))
                            let o = (y * ww + x) * 3
                            e.value[o] = gx * gx; e.value[o + 1] = gx * gy; e.value[o + 2] = gy * gy
                        }
                    }
                }
            }
        }
        FxUtil.gaussBlurN(&efg, ww, wh, 3, Self.tensorSigma(scale))
        // 4. Stroke direction = minor eigenvector (along edges).
        var tangent = [SIMD2<Float>](repeating: .zero, count: ww * wh)
        efg.withUnsafeBufferPointer { eb in
            tangent.withUnsafeMutableBufferPointer { tb in
                let t = UnsafeSendable(tb)
                parallelChunks(ww * wh, minChunk: 1 << 14) { r in
                    for i in r { t.value[i] = Self.tangent(eb[i * 3], eb[i * 3 + 1], eb[i * 3 + 2]) }
                }
            }
        }
        // 5. Line integral convolution over `out` grown by 1 (for the relief gradient).
        let r1 = out.inflate(1).intersect(win)
        let rw = r1.width, rh = r1.height
        let (h, steps) = lic
        var col = [Float](repeating: 0, count: rw * rh * n)
        var bristle = [Float](repeating: 0, count: rw * rh)
        p.withUnsafeBufferPointer { pb in
            tangent.withUnsafeBufferPointer { tb in
                col.withUnsafeMutableBufferPointer { cb in
                    bristle.withUnsafeMutableBufferPointer { bb in
                        let cs = UnsafeSendable(cb), bs = UnsafeSendable(bb)
                        parallelFor(rh) { ry in
                            withStyScratch(n) { acc in
                                for rx in 0..<rw {
                                    let dx = Float(Int(r1.x0 - win.x0) + rx), dy = Float(Int(r1.y0 - win.y0) + ry)
                                    for c in 0..<n { acc[c] = 0 }
                                    var wsum: Float = 0, nsum: Float = 0
                                    Self.sample(pb, ww, wh, n, dx, dy, acc, 1)
                                    wsum += 1
                                    nsum += hash01(win.x0 + StylizeKit.i32(dx), win.y0 + StylizeKit.i32(dy), 71, 0)
                                    for dir: Float in [1, -1] {
                                        var qx = dx, qy = dy
                                        var px: Float = 0, py: Float = 0
                                        for k in 1...max(steps, 1) where k <= steps {
                                            let ti = Int(clampf(qy.rounded(.toNearestOrAwayFromZero), 0, Float(wh - 1))) * ww
                                                + Int(clampf(qx.rounded(.toNearestOrAwayFromZero), 0, Float(ww - 1)))
                                            var t = tb[ti]
                                            if k == 1 {
                                                t = t * dir
                                            } else if t.x * px + t.y * py < 0 {
                                                t = -t
                                            }
                                            px = t.x; py = t.y
                                            qx += t.x * h
                                            qy += t.y * h
                                            let wk = 1 - Float(k) / Float(steps + 1)
                                            Self.sample(pb, ww, wh, n, qx, qy, acc, wk)
                                            wsum += wk
                                            nsum += wk * hash01(win.x0 &+ StylizeKit.i32(qx.rounded(.toNearestOrAwayFromZero)),
                                                                win.y0 &+ StylizeKit.i32(qy.rounded(.toNearestOrAwayFromZero)), 71, 0)
                                        }
                                    }
                                    let o = (ry * rw + rx) * n
                                    for c in 0..<n { cs.value[o + c] = acc[c] / wsum }
                                    bs.value[ry * rw + rx] = nsum / wsum - 0.5
                                }
                            }
                        }
                    }
                }
            }
        }
        // 6. Relief lighting.
        let lt = light
        let amp = clampf(bristleDetail, 0, 10) / 10
        let shine = clampf(self.shine, 0, 10) / 10
        let sub = ctx.mode == .cmyk, lab = ctx.mode == .lab
        let lighting = self.lighting
        let ow = out.width
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            col.withUnsafeBufferPointer { cb in
                bristle.withUnsafeBufferPointer { bb in
                    res.withStyOut { d in
                        @inline(__always) func height(_ rx: Int, _ ry: Int) -> Float {
                            let o = (ry * rw + rx) * n
                            var l: Float = 0
                            for c in 0..<cc { l += cb[o + c] }
                            l /= Float(cc)
                            if sub { l = 1 - l }
                            return l * 2 + bb[ry * rw + rx] * amp * 6
                        }
                        parallelFor(out.height) { row in
                            let y = out.y0 + Int32(row)
                            for i in 0..<ow {
                                let x = out.x0 + Int32(i)
                                let rx = Int(x - r1.x0), ry = Int(y - r1.y0)
                                let o = (ry * rw + rx) * n, dO = (row * ow + i) * n
                                let px = UnsafeMutableBufferPointer(start: d.value + dO, count: n)
                                for c in 0..<n { px[c] = cb[o + c] }
                                if alpha {
                                    let a = px[n - 1]
                                    for c in 0..<(n - 1) { px[c] = a > 1e-7 ? px[c] / a : 0 }
                                    // Painting restyles colour, not coverage: keep the layer's own alpha.
                                    px[n - 1] = s.get(x, y, n - 1)
                                }
                                if lighting {
                                    let hx = height(min(rx + 1, rw - 1), ry) - height(max(rx - 1, 0), ry)
                                    let hy = height(rx, min(ry + 1, rh - 1)) - height(rx, max(ry - 1, 0))
                                    let nv0 = -hx * 0.5, nv1 = -hy * 0.5, nv2: Float = 1
                                    let m = (nv0 * nv0 + nv1 * nv1 + 1).squareRoot()
                                    let ndl = (nv0 * lt.light.x + nv1 * lt.light.y + nv2 * lt.light.z) / m
                                    let ndh = StylizeKit.fmax((nv0 * lt.half.x + nv1 * lt.half.y + nv2 * lt.half.z) / m, 0)
                                    let shade = 1 + (ndl - lt.light.z) * 1.2
                                    let specV = shine * StylizeKit.fmax(powf(ndh, 40) - lt.flatSpec, 0) * 0.8
                                    let chans = lab ? 1 : cc
                                    for c in 0..<chans {
                                        let v = px[c]
                                        px[c] = sub ? 1 - ((1 - v) * shade + specV) : v * shade + specV
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return res
    }

    /// The minor eigenvector of the tensor (E, F, G); flat or isotropic structure gets gentle
    /// diagonal strokes.
    @inline(__always)
    static func tangent(_ e: Float, _ f: Float, _ g: Float) -> SIMD2<Float> {
        let l1 = 0.5 * (e + g + ((e - g) * (e - g) + 4 * f * f).squareRoot())
        let tx = l1 - e, ty = -f
        let m = (tx * tx + ty * ty).squareRoot()
        if m < 1e-6 || (l1 - (e + g - l1)) < 1e-6 { return SIMD2(0.70710677, 0.70710677) }
        return SIMD2(tx / m, ty / m)
    }

    /// Adds the bilinear sample of the window buffer at window coordinates (clamped), times `k`.
    @inline(__always)
    static func sample(_ p: UnsafeBufferPointer<Float>, _ ww: Int, _ wh: Int, _ n: Int, _ x: Float, _ y: Float,
                       _ acc: UnsafeMutableBufferPointer<Float>, _ k: Float) {
        let x = clampf(x, 0, Float(ww - 1)), y = clampf(y, 0, Float(wh - 1))
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let x1 = min(x0 + 1, ww - 1), y1 = min(y0 + 1, wh - 1)
        let ax = x - Float(x0), ay = y - Float(y0)
        let w00 = (1 - ax) * (1 - ay) * k, w10 = ax * (1 - ay) * k, w01 = (1 - ax) * ay * k, w11 = ax * ay * k
        let i00 = (y0 * ww + x0) * n, i10 = (y0 * ww + x1) * n, i01 = (y1 * ww + x0) * n, i11 = (y1 * ww + x1) * n
        for c in 0..<n {
            acc[c] += p[i00 + c] * w00 + p[i10 + c] * w10 + p[i01 + c] * w01 + p[i11 + c] * w11
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let win = pass.srcRect, out = pass.out
        let r1 = out.inflate(1).intersect(win)
        let (h, steps) = lic
        let lt = light
        let cc = pass.ctx.colorChannels(StylizeKit.imageChannels(pass))
        let p = OilParams(win: SIMD2(Int32(win.width), Int32(win.height)), r1Off: SIMD2(r1.x0 - win.x0, r1.y0 - win.y0),
                          r1Size: SIMD2(Int32(r1.width), Int32(r1.height)), winOrigin: SIMD2(win.x0, win.y0),
                          light: SIMD4(lt.light, 0), half: SIMD4(lt.half, 0),
                          h: h, steps: steps, flatSpec: lt.flatSpec, amp: clampf(bristleDetail, 0, 10) / 10,
                          shine: clampf(shine, 0, 10) / 10, lighting: lighting ? 1 : 0, sub: pass.ctx.mode == .cmyk ? 1 : 0,
                          lab: pass.ctx.mode == .lab ? 1 : 0, cc: Int32(cc))
        let ww = win.width, wh = win.height
        if out.isEmpty { return }
        // 1. Premultiplied, cleaned colour over the window.
        let pre = try pass.texture(win)
        try pass.dispatch("pca_sty_oil_premul", params: p, textures: [pass.src, pre], width: ww, height: wh)
        let clean = try pass.styGaussBlurN(pre, rect: win, sigma: clampf(cleanliness, 0, 10) * 0.25)
        if clean !== pre { pass.recycle(pre) }
        // 2–3. Structure tensor of the channel mean, smoothed.
        let efg = try pass.texture(win)
        try pass.dispatch("pca_sty_oil_tensor", params: p, textures: [clean, efg], width: ww, height: wh)
        let efgS = try pass.styGaussBlurN(efg, rect: win, sigma: Self.tensorSigma(scale))
        if efgS !== efg { pass.recycle(efg) }
        // 4. Stroke directions.
        let tan = try pass.texture(win)
        try pass.dispatch("pca_sty_oil_tangent", params: p, textures: [efgS, tan], width: ww, height: wh)
        pass.recycle(efgS)
        // 5. Line integral convolution of colour and bristle noise over `out` grown by 1.
        let col = try pass.texture(r1), br = try pass.texture(r1)
        try pass.dispatch("pca_sty_oil_lic", params: p, textures: [clean, tan, col, br], width: r1.width, height: r1.height)
        pass.recycle(clean)
        pass.recycle(tan)
        // 6. Relief lighting.
        try pass.dispatchOut("pca_sty_oil_out", params: p, textures: [pass.src, col, br, pass.dst])
    }
}

/// MSL `pca_sty_oil_params`.
private struct OilParams: BitwiseCopyable {
    var win: SIMD2<Int32>
    var r1Off: SIMD2<Int32>
    var r1Size: SIMD2<Int32>
    var winOrigin: SIMD2<Int32>
    var light: SIMD4<Float>
    var half: SIMD4<Float>
    var h: Float
    var steps: Int32
    var flatSpec: Float
    var amp: Float
    var shine: Float
    var lighting: Int32
    var sub: Int32
    var lab: Int32
    var cc: Int32
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var pad2: Int32 = 0
}

extension GPUPass {
    /// `FxUtil.gaussBlurN` on a float4 texture covering `rect` (from texel 0, 0), with the box
    /// sums carried in float-float (MSL `pca_sty_box_ff`) so results equal the CPU's f64 running
    /// sums rounded to float. Oil Paint's stroke field follows rounded positions, which a one-ulp
    /// difference in the blurred tensor can flip; `encodeGaussBlurN` rounds `(s + e) · norm` in
    /// f32. Intermediates are recycled (not `tex`, nor the result).
    func styGaussBlurN(_ tex: any MTLTexture, rect: PixelRect, sigma: Float) throws -> any MTLTexture {
        if sigma < 0.3 || rect.isEmpty { return tex }
        let radii = FxUtil.gaussBoxRadii(sigma)
        var cur = tex
        let segment: Int32 = 32
        for axis in [Int32(0), 1] {
            for r in radii where r > 0 {
                let norm = 1 / Double(2 * r + 1)
                let nh = Float(norm)
                let p = StyFFParams(size: SIMD2(Int32(rect.width), Int32(rect.height)), radius: Int32(r), axis: axis, segment: segment,
                                    normHi: nh, normLo: Float(norm - Double(nh)))
                let o = try texture(rect)
                let lines = axis == 0 ? rect.height : rect.width, len = axis == 0 ? rect.width : rect.height
                try dispatch("pca_sty_box_ff", params: p, textures: [cur, o], width: lines,
                             height: (len + Int(segment) - 1) / Int(segment), threadgroup: (32, 4))
                if cur !== tex { recycle(cur) }
                cur = o
            }
        }
        return cur
    }
}

/// MSL `pca_sty_ff_params`.
private struct StyFFParams: BitwiseCopyable {
    var size: SIMD2<Int32>
    var radius: Int32
    var axis: Int32
    var segment: Int32
    var normHi: Float
    var normLo: Float
    var pad0: Int32 = 0
}
