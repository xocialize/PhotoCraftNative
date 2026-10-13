// Port of photocraft-algo (crates/algo/src/artistic_fx.rs `F::GlowingEdges`, `effect_reach`, `run`; artistic.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Stylize › Glowing Edges. photocraft implements it as a Filter Gallery effect; this is
// that effect as a standalone filter with the gallery's maths: an sRGB working copy of the whole
// source window, smoothed (`blur3`), Sobel magnitude per channel (`grad_mag`, edges clamped to
// the window), the edge planes blurred by the edge width and scaled by the brightness, then
// written back in the document's model with the source alpha.

import Metal
import PCFoundation

/// Filter › Stylize › Glowing Edges: `edgeWidth` 1–14, `edgeBrightness` 0–20, `smoothness` 1–15.
public struct GlowingEdges: Filter, Hashable {
    public var edgeWidth: Float
    public var edgeBrightness: Float
    public var smoothness: Float
    public init(edgeWidth: Float = 2, edgeBrightness: Float = 6, smoothness: Float = 5) {
        self.edgeWidth = edgeWidth; self.edgeBrightness = edgeBrightness; self.smoothness = smoothness
    }
    public var label: String { "Glowing Edges" }

    /// Blur sigmas (a non-finite parameter disables the blur rather than reaching the box
    /// radii, which need a finite sigma).
    var smoothSigma: Float { Self.finite(0.3 + smoothness * 0.25) }
    var edgeSigma: Float { Self.finite(edgeWidth * 0.4) }
    static func finite(_ s: Float) -> Float { s.isFinite ? min(s, 1e4) : 0 }
    var gain: Float { 2 + edgeBrightness * 1.2 }

    /// photocraft `gs`: pixels a three-box Gaussian of `sigma` reads.
    static func gs(_ sigma: Float) -> Int32 {
        sigma < 0.3 ? 0 : Int32(FxUtil.gaussBoxRadii(sigma).reduce(0, +)) + 1
    }
    /// The gallery's `effect_reach` (a plain radius, as `Halo::Radius(artistic_fx::reach)`).
    public func halo(bounds: PixelRect) -> Halo {
        .radius(Self.gs(smoothSigma) + Self.gs(edgeSigma) + 2)
    }
    /// The effect works on sRGB colour: Gray- and RGB-like models on the GPU.
    public var gpuChannels: GPUChannels { .joint }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        let r = src.rect
        let w = r.width, h = r.height
        var res = src.crop(out)
        if w == 0 || h == 0 || n == 0 || out.isEmpty { return res }
        // The working window: sRGB of every source pixel.
        var c = [Float](repeating: 0, count: w * h * 3)
        src.data.withUnsafeBufferPointer { sb in
            c.withUnsafeMutableBufferPointer { cb in
                let cs = UnsafeSendable(cb)
                parallelChunks(w * h, minChunk: 1 << 12) { range in
                    for i in range {
                        let v = ctx.rgba(UnsafeBufferPointer(rebasing: sb[(i * n)..<((i + 1) * n)]))
                        cs.value[i * 3] = v.x; cs.value[i * 3 + 1] = v.y; cs.value[i * 3 + 2] = v.z
                    }
                }
            }
        }
        FxUtil.gaussBlurN(&c, w, h, 3, smoothSigma)
        // Sobel magnitude per channel, edges clamped to the window.
        var e3 = [Float](repeating: 0, count: w * h * 3)
        c.withUnsafeBufferPointer { cb in
            e3.withUnsafeMutableBufferPointer { eb in
                let es = UnsafeSendable(eb)
                parallelFor(h) { y in
                    @inline(__always) func at(_ x: Int, _ yy: Int, _ ch: Int) -> Float {
                        cb[(min(max(yy, 0), h - 1) * w + min(max(x, 0), w - 1)) * 3 + ch]
                    }
                    for x in 0..<w {
                        for ch in 0..<3 {
                            let gx = ((at(x + 1, y - 1, ch) + 2 * at(x + 1, y, ch) + at(x + 1, y + 1, ch))
                                - (at(x - 1, y - 1, ch) + 2 * at(x - 1, y, ch) + at(x - 1, y + 1, ch))) / 8
                            let gy = ((at(x - 1, y + 1, ch) + 2 * at(x, y + 1, ch) + at(x + 1, y + 1, ch))
                                - (at(x - 1, y - 1, ch) + 2 * at(x, y - 1, ch) + at(x + 1, y - 1, ch))) / 8
                            es.value[(y * w + x) * 3 + ch] = (gx * gx + gy * gy).squareRoot()
                        }
                    }
                }
            }
        }
        FxUtil.gaussBlurN(&e3, w, h, 3, edgeSigma)
        let k = gain
        let ow = out.width, alpha = ctx.alpha
        e3.withUnsafeBufferPointer { eb in
            res.withStyOut { d in
                parallelFor(out.height) { row in
                    let y = out.y0 + Int32(row)
                    for i in 0..<ow {
                        let x = out.x0 + Int32(i)
                        // `Win::at`: the window pixel nearest (x, y).
                        let xx = Int(min(max(x - r.x0, 0), Int32(w) - 1)), yy = Int(min(max(y - r.y0, 0), Int32(h) - 1))
                        let o = (yy * w + xx) * 3
                        let px = UnsafeMutableBufferPointer(start: d.value + (row * ow + i) * n, count: n)
                        let a: Float = alpha ? px[n - 1] : 1
                        let col = SIMD4(clampf(clampf(eb[o] * k, 0, 1), 0, 1), clampf(clampf(eb[o + 1] * k, 0, 1), 0, 1),
                                        clampf(clampf(eb[o + 2] * k, 0, 1), 0, 1), a)
                        ctx.setRGBA(px, col)
                        if alpha { px[n - 1] = a }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let win = pass.srcRect
        let p = GlowParams(winOrigin: SIMD2(win.x0, win.y0), winSize: SIMD2(Int32(win.width), Int32(win.height)), gain: gain)
        let rgb = try pass.texture(win)
        try pass.dispatch("pca_sty_glow_rgb", params: p, textures: [pass.src, rgb], width: win.width, height: win.height)
        let smooth = try pass.encodeGaussBlurN(rgb, rect: win, sigma: smoothSigma)
        if smooth !== rgb { pass.recycle(rgb) }
        let edges = try pass.texture(win)
        try pass.dispatch("pca_sty_glow_sobel", params: p, textures: [smooth, edges], width: win.width, height: win.height)
        pass.recycle(smooth)
        let glow = try pass.encodeGaussBlurN(edges, rect: win, sigma: edgeSigma)
        if glow !== edges { pass.recycle(edges) }
        try pass.dispatchOut("pca_sty_glow_out", params: p, textures: [pass.src, glow, pass.dst])
    }
}

/// MSL `pca_sty_glow_params`.
private struct GlowParams: BitwiseCopyable {
    var winOrigin: SIMD2<Int32>
    var winSize: SIMD2<Int32>
    var gain: Float
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var pad2: Int32 = 0
}
