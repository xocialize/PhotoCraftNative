// Port of photocraft-algo (crates/algo/src/blur.rs: surface, surface_direct), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Surface Blur: each colour sample becomes the mean of its window weighted by `1 − |v − v0| / t`
// (t = 2.5 × threshold), transparent pixels skipped. photocraft picks among a direct sum, an 8-bit
// sliding histogram and a ranked Fenwick-tree sum that agree within 1e-5 (its own tests); the
// reference here is the direct sum, which the Metal kernel mirrors tap for tap.

import Metal
import PCFoundation

/// Filter › Blur › Surface Blur: radius px, threshold levels.
public struct SurfaceBlur: Filter, Hashable {
    public var radius: Float
    public var threshold: Float
    public init(radius: Float = 5, threshold: Float = 15) { self.radius = radius; self.threshold = threshold }
    public var label: String { "Surface Blur" }
    public func halo(bounds: PixelRect) -> Halo { .reach(radius) }

    var r: Int32 { PCAMath.i32(PCAMath.pos(radius).rounded(.toNearestOrAwayFromZero)) }
    var t: Float { (max(threshold, 1) / 255) * 2.5 }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels, cc = ctx.colorChannels(n)
        let r = self.r, t = self.t
        var res = FloatImage(rect: out, channels: n)
        res.data.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelChunks(out.height, minChunk: 1) { rows in
                for oy in rows {
                    let y = out.y0 + Int32(oy)
                    for x in out.x0..<out.x1 {
                        let o = (oy * out.width + Int(x - out.x0)) * n
                        for c in 0..<cc {
                            let v0 = src.get(x, y, c)
                            var acc: Float = 0, wsum: Float = 0
                            for yy in (y - r)...(y + r) {
                                for xx in (x - r)...(x + r) {
                                    if ctx.alpha && src.get(xx, yy, n - 1) <= 0 { continue }
                                    let v = src.get(xx, yy, c)
                                    let w = max(1 - abs(v - v0) / t, 0)
                                    acc += v * w
                                    wsum += w
                                }
                            }
                            rs.value[o + c] = wsum > 0 ? acc / wsum : v0
                        }
                        if ctx.alpha { rs.value[o + n - 1] = src.get(x, y, n - 1) }
                    }
                }
            }
        }
        return res
    }

    struct Params: BitwiseCopyable { var r: Int32; var t: Float; var pad0: Float = 0; var pad1: Float = 0 }
    public func encodeGPU(_ pass: GPUPass) throws {
        if r <= 8 {
            let side = 16 + 2 * Int(r)
            try pass.dispatch("pca_surface_blur_tg", params: Params(r: r, t: t), textures: [pass.src, pass.dst],
                              width: pass.out.width, height: pass.out.height, threadgroup: (16, 16), threadgroupMemory: [side * side * 16])
        } else {
            try pass.dispatchOut("pca_surface_blur", params: Params(r: r, t: t))
        }
    }
}
