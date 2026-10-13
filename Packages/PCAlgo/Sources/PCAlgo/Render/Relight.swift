// Port of photocraft-algo (crates/algo/src/relight.rs, lib.rs halo_for), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Render › Relight: recover the shading with a blur of the Rec. 709 luma (Retinex) and
// replace it with a Lambertian lamp whose direction comes from angle / elevation. The blur is
// fxutil's three-box `gauss_blur_n` over a (luma, weight) field so non-finite and transparent
// pixels are held out; σ follows the softness and the bounds, and so does the halo
// (photocraft `halo_for`). Outputs whose inflated luma field would exceed 8 MP are processed in
// horizontal bands exactly as photocraft does. Metal: Shaders/RenderRelight.metal (`.joint`).

import Foundation
import PCFoundation

/// photocraft `relight` constants and helpers.
enum RelightKit {
    /// Softness maps onto this σ range; the halo is derived from the σ actually used.
    static let sigmaMin: Float = 2
    static let sigmaMax: Float = 96
    /// The finite-difference step is σ, but never more than this many pixels.
    static let stepMax: Float = 32
    /// Luma field allocated for one kernel call; larger outputs are split into bands.
    static let maxLumaPixels = 8_000_000

    /// Blur σ from softness and the reference bounds, clamped to [sigmaMin, sigmaMax].
    static func sigma(_ softness: Float, _ bounds: PixelRect) -> Float {
        let side = Float(min(bounds.width, bounds.height))
        let s = (clampf(softness, 1, 100) / 100) * 0.08 * Float.maximum(side, 1)
        return clampf(s, sigmaMin, sigmaMax)
    }

    /// Finite-difference step (pixels) at this σ.
    static func step(_ sig: Float) -> Int32 { DistortKit.floorToInt(clampf(sig.rounded(), 1, stepMax)) }

    /// Pixels read outside an output tile: `3σ + 1` of the blur plus the finite-difference step.
    static func readRadius(_ sig: Float) -> Int32 {
        let blur = Int32((Float.maximum(sig, 0) * 3).rounded(.up)) + 1
        return blur.addingReportingOverflow(step(sig)).overflow ? Int32.max : blur + step(sig)
    }

    /// Halo for a concrete document size (the σ-max halo when `bounds` is empty).
    static func haloRadius(_ softness: Float, _ bounds: PixelRect) -> Int32 {
        bounds.isEmpty ? haloRadiusMax : readRadius(sigma(softness, bounds))
    }

    /// Conservative halo when the document size is unknown: covers sigmaMax.
    static var haloRadiusMax: Int32 { readRadius(sigmaMax) }

    /// photocraft relight's `norm3` (non-finite or tiny → straight up).
    static func norm3(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let m = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        if !m.isFinite || m < 1e-9 { return SIMD3(0, 0, 1) }
        return SIMD3(v.x / m, v.y / m, v.z / m)
    }

    /// Infinite-light direction: 0° from the right, 90° from above (image space, y down).
    static func lightDir(_ angle: Float, _ elevation: Float) -> SIMD3<Float> {
        let a = DistortKit.radians(angle)
        let s = sinf(a), co = cosf(a)
        let e = DistortKit.radians(clampf(elevation, 0, 90))
        return norm3(SIMD3(co * cosf(e), -s * cosf(e), sinf(e)))
    }

    static func lightColor(_ warmth: Float) -> SIMD3<Float> {
        let w = clampf(warmth, -100, 100) / 100
        if w >= 0 { return SIMD3(1 + 0.15 * w, 1 - 0.05 * w, 1 - 0.25 * w) }
        let t = -w
        return SIMD3(1 - 0.20 * t, 1 - 0.10 * t, 1 + 0.15 * t)
    }

    @inline(__always)
    static func rec709Y(_ c: SIMD4<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    @inline(__always)
    static func finite(_ c: SIMD4<Float>) -> Bool { c.x.isFinite && c.y.isFinite && c.z.isFinite && c.w.isFinite }

    /// Band height so the inflated luma field stays within `limit` pixels (nil: one piece).
    static func bandRows(_ out: PixelRect, _ reach: Int32, limit: Int) -> Int32? {
        let margin = 2 * Int(max(reach, 0))
        let yw = out.width + margin, yh = out.height + margin
        if yw == 0 { return nil }
        let (n, ovf) = yw.multipliedReportingOverflow(by: yh)
        if !ovf && n == 0 { return nil }
        if !ovf && n <= limit { return nil }
        let maxYH = max(limit / yw, 1)
        let inner = Int32(min(max(maxYH - margin, 1), Int(Int32.max)))
        return inner >= Int32(out.height) ? nil : max(inner, 1)
    }

    /// The bands of `out` (one piece unless the luma field would exceed `limit`).
    static func bands(_ out: PixelRect, _ reach: Int32, limit: Int) -> [PixelRect] {
        guard let bh = bandRows(out, reach, limit: limit) else { return [out] }
        var res: [PixelRect] = []
        var y = out.y0
        while y < out.y1 {
            let y1 = min(y + bh, out.y1)
            res.append(PixelRect(x0: out.x0, y0: y, x1: out.x1, y1: y1))
            y = y1
        }
        return res
    }
}

struct RenderRelightGPU: BitwiseCopyable {
    var yOrigin: SIMD2<Int32>; var ySize: SIMD2<Int32>
    var dstOrigin: SIMD2<Int32>; var step: Int32; var amb: Float
    var ldir: SIMD4<Float>   // light direction, w = intensity 0…1
    var lcol: SIMD4<Float>
}

/// Filter › Render › Relight: photographic relighting. Angle −180…180°, elevation 0…90°,
/// intensity/ambient 0…100, warmth −100…100, softness 1…100. Intensity 0 is an identity copy.
public struct Relight: Filter, Hashable {
    public var angle: Float
    public var elevation: Float
    public var intensity: Float
    public var ambient: Float
    public var warmth: Float
    public var softness: Float
    /// Luma-field budget per kernel call (photocraft `MAX_LUMA_PIXELS`); internal, for tests.
    var maxLumaPixels: Int = RelightKit.maxLumaPixels

    enum CodingKeys: String, CodingKey { case angle, elevation, intensity, ambient, warmth, softness }

    public init(angle: Float = 45, elevation: Float = 40, intensity: Float = 40, ambient: Float = 55, warmth: Float = 0, softness: Float = 25) {
        self.angle = angle; self.elevation = elevation; self.intensity = intensity; self.ambient = ambient
        self.warmth = warmth; self.softness = softness
    }

    public var label: String { "Relight" }
    public var gpuChannels: GPUChannels { .joint }

    /// photocraft `halo_for`: 0 at intensity 0, else `3σ + 1 + step` for this bounds' σ.
    public func halo(bounds: PixelRect) -> Halo {
        intensity == 0 ? .radius(0) : .radius(RelightKit.haloRadius(softness, bounds))
    }

    var isIdentity: Bool { !intensity.isFinite || intensity == 0 }

    /// The light: direction with intensity 0…1 in `.w`, colour, ambient 0…1.
    var lamp: (SIMD4<Float>, SIMD4<Float>, Float) {
        let amb = clampf(ambient.isFinite ? ambient : 0, 0, 100) / 100
        return (SIMD4(RelightKit.lightDir(angle, elevation), clampf(intensity, 0, 100) / 100), SIMD4(RelightKit.lightColor(warmth), 0), amb)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        if out.isEmpty || n == 0 || isIdentity { return src.crop(out) }
        let sig = RelightKit.sigma(softness, ctx.bounds)
        let reach = RelightKit.readRadius(sig)
        let bands = RelightKit.bands(out, reach, limit: maxLumaPixels)
        if bands.count == 1 { return relightRect(src, out, ctx, sig) }
        var res = src.crop(out)
        for band in bands {
            let part = relightRect(src, band, ctx, sig)
            let w = band.width * n
            for y in band.y0..<band.y1 {
                let d = res.index(x: band.x0, y: y), s = part.index(x: band.x0, y: y)
                res.data.replaceSubrange(d..<d + w, with: part.data[s..<s + w])
            }
        }
        return res
    }

    /// photocraft `relight_rect`.
    func relightRect(_ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext, _ sig: Float) -> FloatImage {
        let n = src.channels
        var res = src.crop(out)
        let step = RelightKit.step(sig)
        // Finite differences at the shading scale (σ), not 1 px.
        let scale: Float = 2
        let yRect = out.inflate(RelightKit.readRadius(sig))
        if yRect.isEmpty { return res }
        let yw = yRect.width, yh = yRect.height
        // (luma, weight) per pixel: non-finite or transparent pixels are held out of the blur.
        var packed = [Float](repeating: 0, count: yw * yh * 2)
        packed.withUnsafeMutableBufferPointer { pb in
            let p = UnsafeSendable(pb)
            parallelChunks(yh, minChunk: 8) { rows in
                withUnsafeTemporaryAllocation(of: Float.self, capacity: max(n, 1)) { tmp in
                    for oy in rows {
                        let y = yRect.y0 + Int32(oy)
                        for ox in 0..<yw {
                            let x = yRect.x0 + Int32(ox)
                            for c in 0..<n { tmp[c] = src.get(x, y, c) }
                            let c = ctx.rgba(UnsafeBufferPointer(rebasing: tmp[0..<n]))
                            var v = Float.nan
                            if RelightKit.finite(c) {
                                let a: Float = ctx.alpha ? c.w : 1
                                if a > 0 && a.isFinite { v = RelightKit.rec709Y(c) }
                            }
                            if v.isFinite {
                                p.value[(oy * yw + ox) * 2] = v
                                p.value[(oy * yw + ox) * 2 + 1] = 1
                            }
                        }
                    }
                }
            }
        }
        FxUtil.gaussBlurN(&packed, yw, yh, 2, sig)
        var sbuf = [Float](repeating: 0.5, count: yw * yh)
        for i in 0..<(yw * yh) {
            let acc = packed[i * 2], wgt = packed[i * 2 + 1]
            sbuf[i] = wgt > 1e-6 && acc.isFinite && wgt.isFinite ? acc / wgt : 0.5
        }
        let (ldir, lcol, amb) = lamp
        let inten = ldir.w
        sbuf.withUnsafeBufferPointer { sb in
            @inline(__always) func sampleY(_ x: Int32, _ y: Int32) -> Float {
                let xx = min(max(x, yRect.x0), yRect.x1 - 1), yy = min(max(y, yRect.y0), yRect.y1 - 1)
                let v = sb[Int(yy - yRect.y0) * yw + Int(xx - yRect.x0)]
                return v.isFinite ? v : 0.04
            }
            RenderKit.forEachPixel(&res) { x, y, px in
                for v in px where !v.isFinite { return }
                let a: Float = ctx.alpha ? px[n - 1] : 1
                if ctx.alpha && a <= 0 { return }
                let c = ctx.rgba(UnsafeBufferPointer(px))
                if !RelightKit.finite(c) { return }
                let s0 = Float.maximum(sampleY(x, y), 0.04)
                let nx = (sampleY(x - step, y) - sampleY(x + step, y)) * scale
                let ny = (sampleY(x, y - step) - sampleY(x, y + step)) * scale
                let nrm = RelightKit.norm3(SIMD3(nx, ny, 1))
                let ndl = Float.maximum(nrm.x * ldir.x + nrm.y * ldir.y + nrm.z * ldir.z, 0)
                let shade = amb + inten * ndl
                var o = c
                o.x = (c.x / s0) * shade * lcol.x
                o.y = (c.y / s0) * shade * lcol.y
                o.z = (c.z / s0) * shade * lcol.z
                if !RelightKit.finite(o) { return }
                ctx.setRGBA(px, o)
                if ctx.alpha { px[n - 1] = a }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let out = pass.out
        if isIdentity {
            try pass.dispatchOut("pca_copy", params: NoParams())
            return
        }
        let sig = RelightKit.sigma(softness, pass.ctx.bounds)
        let reach = RelightKit.readRadius(sig)
        let (ldir, lcol, amb) = lamp
        for band in RelightKit.bands(out, reach, limit: maxLumaPixels) {
            let yRect = band.inflate(reach)
            let p = RenderRelightGPU(yOrigin: SIMD2(yRect.x0, yRect.y0), ySize: SIMD2(Int32(yRect.width), Int32(yRect.height)),
                                     dstOrigin: SIMD2(out.x0, out.y0), step: RelightKit.step(sig), amb: amb, ldir: ldir, lcol: lcol)
            let field = try pass.texture(yRect)
            try pass.dispatch("pca_ren_relight_luma", params: p, textures: [pass.src, field], width: yRect.width, height: yRect.height)
            let blurred = try pass.encodeGaussBlurN(field, rect: yRect, sigma: sig)
            try pass.dispatch("pca_ren_relight_shade", frame: pass.frame.with(out: band), params: p, textures: [pass.src, blurred, pass.dst],
                              width: band.width, height: band.height)
        }
    }
}
