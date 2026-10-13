// Port of photocraft-algo (crates/algo/src/sharpen.rs, resample.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Unsharp Mask as Image Size's Preserve Details runs it after enlarging (amount 30 %, radius
// 0.6 · scale, threshold 0). Area-local until the Sharpen area's public UnsharpMask lands; the
// maths is photocraft's `with_blur`: an exact premultiplied Gaussian (`conv_sep`), then
// `o + k·(o − blur)` on the colour channels where the difference clears the threshold, transparent
// pixels left alone.

import PCFoundation

extension ResampleKit {
    /// MSL `pca_rs_unsharp_params`.
    struct UnsharpParams: BitwiseCopyable {
        var k: Float
        var t: Float
        var pad0: Int32 = 0
        var pad1: Int32 = 0
    }

    /// photocraft `FilterParams::UnsharpMask` (amount %, radius σ px, threshold levels).
    struct Unsharp: Filter, Hashable {
        var amount: Float
        var radius: Float
        var threshold: Float
        var label: String { "Unsharp Mask" }
        func halo(bounds: PixelRect) -> Halo { .gaussian(radius) }

        func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
            let k = amount / 100, t = threshold / 255
            let kern = BlurCore.gaussianKernel(radius)
            let blurred = BlurCore.convSep(src, out, kern, kern, ctx.alpha)
            var res = src.crop(out)
            let n = src.channels
            let cc = ctx.colorChannels(n)
            res.data.withUnsafeMutableBufferPointer { px in
                blurred.data.withUnsafeBufferPointer { bl in
                    for i in 0..<out.area {
                        let b = i * n
                        if ctx.alpha && px[b + n - 1] <= 0 { continue }
                        for c in 0..<cc {
                            let o = px[b + c], d = o - bl[b + c]
                            if abs(d) + 1e-6 >= t { px[b + c] = o + k * d }
                        }
                    }
                }
            }
            return res
        }

        func encodeGPU(_ pass: GPUPass) throws {
            let kern = BlurCore.gaussianKernel(radius)
            let blur = try pass.texture(pass.out)
            try pass.encodeConvSep(input: pass.src, inRect: pass.srcRect, output: blur, outRect: pass.out, kx: kern, ky: kern)
            try pass.dispatchOut("pca_rs_unsharp", params: UnsharpParams(k: amount / 100, t: threshold / 255),
                                 textures: [pass.src, blur, pass.dst])
        }
    }
}
