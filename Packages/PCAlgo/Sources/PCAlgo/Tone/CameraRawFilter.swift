// Port of photocraft-algo (crates/algo/src/camera_raw.rs: develop), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Camera Raw Filter as a `Filter`: the reference bounds are the developed image (the
// vignette is centred on them and grain is positioned in them). The Metal path is one kernel for
// the per-pixel stages — white balance and exposure, Contrast, Vibrance / Saturation, the tone
// curves, the Color Mixer, Color Grading, vignette, grain — used when no stage needs image
// statistics or neighbourhoods (`CameraRaw.isPerPixel`); otherwise the CPU reference runs.

import Metal
import PCFoundation

public struct CameraRawFilter: Filter, Hashable {
    public var settings: CameraRaw
    /// Keep values above 1 (32-bit documents) — photocraft `develop`'s `float`.
    public var float: Bool

    public init(settings: CameraRaw, float: Bool = false) { self.settings = settings; self.float = float }

    // photocraft stores Camera Raw's smart-filter params as the `CameraRaw` fields themselves (every
    // one defaulted); `float` (32-bit documents) rides alongside.
    enum FloatKey: String, CodingKey { case float }
    public init(from decoder: any Decoder) throws {
        settings = try CameraRaw(from: decoder)
        float = try decoder.container(keyedBy: FloatKey.self).decodeIfPresent(Bool.self, forKey: .float) ?? false
    }
    public func encode(to encoder: any Encoder) throws {
        try settings.encode(to: encoder)
        var c = encoder.container(keyedBy: FloatKey.self)
        try c.encode(float, forKey: .float)
    }

    public var label: String { "Camera Raw Filter" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }
    public var gpuChannels: GPUChannels { .joint }

    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool {
        let cc = ctx.colorChannels(channels)
        return settings.isPerPixel && (ctx.mode.isGrayLike || ctx.mode.isRGBLike) && cc <= (ctx.alpha ? 3 : 4)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let b = ctx.bounds
        var px = ToneKit.rgbaPixels(src, b, ctx)
        ToneKit.develop(&px, w: b.width, h: b.height, settings, float: float)
        return ToneKit.writeRGBA(px, b, src, out, ctx)
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        guard settings.isPerPixel else { throw FilterError.gpuUnsupported("\(label) with Dehaze, Highlights/Shadows, Clarity, Texture, Whites/Blacks or Detail") }
        let b = pass.ctx.bounds
        if b.isEmpty {
            try pass.dispatchOut("pca_copy", params: NoParams())
            return
        }
        let s = settings
        let identity = s.isIdentity
        var p = CameraRawKit.GPUParams()
        p.origin = SIMD2(b.x0, b.y0); p.size = SIMD2(Int32(b.width), Int32(b.height))
        var flags: UInt32 = 0
        var luts = [Float](repeating: 0, count: 5 * 1024)
        var hsl = [Float](repeating: 0, count: 24)
        if !identity {
            let ps = clampf(s.pixelScale, 0.01, 1)
            if !s.wbNeutral { flags |= 1; let g = CameraRawKit.wbGains(s); p.wb = SIMD4(g, 0) }
            if !s.localToneNeutral && [s.contrast, s.texture, s.clarity].contains(where: { $0 != 0 }) {
                flags |= 2; p.kCon = s.contrast / 100 * 0.6
            }
            if s.needsColor {
                let plan = CameraRawKit.ColorPlan(s)
                if plan.vibSat { flags |= 4; p.saturation = plan.saturation; p.vibrance = plan.vibrance }
                for (k, lut) in [plan.par, plan.master, plan.chan[0], plan.chan[1], plan.chan[2]].enumerated() {
                    if let l = lut { flags |= 8 << UInt32(k); luts.replaceSubrange((k * 1024)..<((k + 1) * 1024), with: l) }
                }
                if plan.hsl { flags |= 256; hsl = plan.hue + plan.sat + plan.lum }
                if plan.grade {
                    flags |= 512
                    p.tint0 = SIMD4(plan.tints[0], 0); p.tint1 = SIMD4(plan.tints[1], 0)
                    p.tint2 = SIMD4(plan.tints[2], 0); p.tint3 = SIMD4(plan.tints[3], 0)
                    p.lums = SIMD4(plan.lums[0], plan.lums[1], plan.lums[2], plan.lums[3])
                    p.blend = plan.blend; p.bal = plan.bal
                }
            }
            if s.vignetteAmount != 0 {
                flags |= 1024
                let v = CameraRawKit.Vignette(s, b.width, b.height)
                p.vigAmt = v.amt; p.vigHl = v.hl; p.cx = v.cx; p.cy = v.cy; p.ax = v.ax; p.ay = v.ay
                p.pw = v.pw; p.edge0 = v.edge0; p.edge1 = v.edge1; p.vigStyle = v.styleCode
            }
            if s.grainAmount > 0 {
                flags |= 2048
                let g = CameraRawKit.Grain(s, ps)
                p.grainCell = g.cell; p.grainRough = g.rough; p.grainAmt = g.amt; p.grainPscale = g.pscale
                p.seedLo = UInt32(truncatingIfNeeded: g.seed); p.seedHi = UInt32(truncatingIfNeeded: g.seed >> 32)
            }
            if !float { flags |= 4096 }
        }
        p.flags = flags
        try pass.dispatchOut("pca_tone_camera_raw", params: p, buffers: [try pass.buffer(luts), try pass.buffer(hsl)])
    }
}

extension CameraRawKit {
    /// MSL `pca_tone_cr_params`.
    struct GPUParams: BitwiseCopyable {
        var origin = SIMD2<Int32>(), size = SIMD2<Int32>()
        var wb = SIMD4<Float>()
        var tint0 = SIMD4<Float>(), tint1 = SIMD4<Float>(), tint2 = SIMD4<Float>(), tint3 = SIMD4<Float>()
        var lums = SIMD4<Float>()
        var flags: UInt32 = 0, kCon: Float = 0, saturation: Float = 0, vibrance: Float = 0
        var blend: Float = 0, bal: Float = 0, vigAmt: Float = 0, vigHl: Float = 0
        var cx: Float = 0, cy: Float = 0, ax: Float = 1, ay: Float = 1
        var pw: Float = 2, edge0: Float = 0, edge1: Float = 1, vigStyle: UInt32 = 0
        var grainCell: Float = 1, grainRough: Float = 0, grainAmt: Float = 0, grainPscale: Float = 1
        var seedLo: UInt32 = 0, seedHi: UInt32 = 0, pad0: UInt32 = 0, pad1: UInt32 = 0
    }
}
