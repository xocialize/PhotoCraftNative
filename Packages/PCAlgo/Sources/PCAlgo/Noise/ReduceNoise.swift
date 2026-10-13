// Port of photocraft-algo (crates/algo/src/denoise.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Reduce Noise: edge-preserving luminance smoothing, chroma smoothing guided by the luminance,
// optional JPEG deblocking and detail sharpening. Smoothing is the guided filter (He, Sun & Tang,
// ECCV 2010): O(1) per pixel whatever the radius. The whole source window is filtered (box blurs
// clamp at its edge), as photocraft does; the halo keeps that edge away from the output.

import Metal
import PCFoundation

/// Filter › Noise › Reduce Noise: strength 0–10, the rest 0–100 %.
public struct ReduceNoise: Filter, Hashable {
    public var strength: Float
    public var preserveDetails: Float
    public var reduceColorNoise: Float
    public var sharpenDetails: Float
    public var removeJpegArtifact: Bool
    public init(strength: Float = 6, preserveDetails: Float = 60, reduceColorNoise: Float = 45, sharpenDetails: Float = 25,
                removeJpegArtifact: Bool = false) {
        self.strength = strength; self.preserveDetails = preserveDetails; self.reduceColorNoise = reduceColorNoise
        self.sharpenDetails = sharpenDetails; self.removeJpegArtifact = removeJpegArtifact
    }
    public var label: String { "Reduce Noise" }

    static let maxLumaR = 5
    static let maxChromaR = 9
    /// Pixels read beyond an output tile (photocraft `denoise::reach`).
    static var reach: Float { Float(2 * maxLumaR + 2 * maxChromaR + 6) }
    public func halo(bounds: PixelRect) -> Halo { .reach(Self.reach) }

    enum Model: UInt32 { case gray = 0, ycc = 1, lab = 2, viaRGB = 3 }
    static func model(_ mode: ColorMode) -> Model {
        switch mode {
        case .grayscale, .bitmap, .duotone: .gray
        case .rgb: .ycc
        case .lab: .lab
        default: .viaRGB
        }
    }

    public var gpuChannels: GPUChannels { .joint }
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool {
        let m = Self.model(ctx.mode)
        return m != .viaRGB && ctx.colorChannels(channels) <= 3
    }

    var s: Float { clampf(strength, 0, 10) / 10 }
    var col: Float { clampf(reduceColorNoise, 0, 100) / 100 }
    var sh: Float { clampf(sharpenDetails, 0, 100) / 100 }
    var lumaR: Int { min(Int((1 + clampf(strength, 0, 10) * 0.4).rounded(.toNearestOrAwayFromZero)), Self.maxLumaR) }
    var lumaEps: Float {
        let keep = clampf(preserveDetails, 0, 100) / 100
        let e = 0.004 + 0.05 * s
        return e * e * (1.05 - keep)
    }
    var chromaR: Int { min(Int((1 + col * 8).rounded(.toNearestOrAwayFromZero)), Self.maxChromaR) }
    var chromaEps: Float { let e = 0.01 + 0.05 * col; return e * e }
    var isIdentity: Bool { s <= 0 && col <= 0 && sh <= 0 && !removeJpegArtifact }

    /// Guided filter of `p` with guide `g` (both `w × h`), box radius `r` (photocraft `guided`).
    static func guided(_ g: [Float], _ p: [Float], _ w: Int, _ h: Int, _ r: Int, _ eps: Float) -> [Float] {
        let len = w * h
        var m = [Float](repeating: 0, count: len * 4)
        for i in 0..<len {
            m[i * 4] = g[i]; m[i * 4 + 1] = p[i]; m[i * 4 + 2] = g[i] * g[i]; m[i * 4 + 3] = g[i] * p[i]
        }
        FxUtil.boxBlurN(&m, w, h, 4, r)
        var ab = [Float](repeating: 0, count: len * 2)
        for i in 0..<len {
            let mg = m[i * 4], mp = m[i * 4 + 1], mgg = m[i * 4 + 2], mgp = m[i * 4 + 3]
            let v = max(mgg - mg * mg, 0)
            let a = (mgp - mg * mp) / (v + eps)
            ab[i * 2] = a
            ab[i * 2 + 1] = mp - a * mg
        }
        FxUtil.boxBlurN(&ab, w, h, 2, r)
        return (0..<len).map { ab[$0 * 2] * g[$0] + ab[$0 * 2 + 1] }
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        let win = src.rect
        let ww = win.width, wh = win.height, len = ww * wh
        if isIdentity || len == 0 { return src.crop(out) }
        let model = Self.model(ctx.mode)
        var yv = [Float](repeating: 0, count: len)
        var c1 = [Float](repeating: 0, count: model == .gray ? 0 : len)
        var c2 = [Float](repeating: 0, count: model == .gray ? 0 : len)
        src.data.withUnsafeBufferPointer { sp in
            for i in 0..<len {
                let px = UnsafeBufferPointer(rebasing: sp[(i * n)..<(i * n + n)])
                switch model {
                case .gray: yv[i] = px[0]
                case .lab: yv[i] = px[0]; c1[i] = px[1]; c2[i] = px[2]
                case .ycc, .viaRGB:
                    let c = model == .ycc ? SIMD4(px[0], px[1], px[2], 1) : ctx.rgba(px)
                    let l = 0.299 * c.x + 0.587 * c.y + 0.114 * c.z
                    yv[i] = l; c1[i] = c.z - l; c2[i] = c.x - l
                }
            }
        }
        // JPEG deblocking: soften luma across the 8×8 grid lines (document-anchored).
        if removeJpegArtifact && wh > 2 && ww > 2 {
            let orig = yv
            for yy in 1..<(wh - 1) {
                for xx in 1..<(ww - 1) {
                    let dx = euclidMod(win.x0 + Int32(xx), 8), dy = euclidMod(win.y0 + Int32(yy), 8)
                    if dx == 0 || dx == 7 || dy == 0 || dy == 7 {
                        var a: Float = 0
                        for j in 0..<3 { for k in 0..<3 { a += orig[(yy + j - 1) * ww + xx + k - 1] } }
                        yv[yy * ww + xx] = 0.5 * orig[yy * ww + xx] + 0.5 * a / 9
                    }
                }
            }
        }
        if s > 0 {
            let d = Self.guided(yv, yv, ww, wh, lumaR, lumaEps)
            let k = s.squareRoot()
            for i in 0..<len { yv[i] += (d[i] - yv[i]) * k }
        }
        if col > 0 && model != .gray {
            for plane in 0..<2 {
                let p = plane == 0 ? c1 : c2
                let d = Self.guided(yv, p, ww, wh, chromaR, chromaEps)
                var q = p
                for i in 0..<len { q[i] += (d[i] - q[i]) * col }
                if plane == 0 { c1 = q } else { c2 = q }
            }
        }
        if sh > 0 {
            var bl = yv
            FxUtil.gaussBlurN(&bl, ww, wh, 1, 1)
            for i in 0..<len { yv[i] += (yv[i] - bl[i]) * sh * 1.2 }
        }
        var res = src.crop(out)
        res.data.withUnsafeMutableBufferPointer { rp in
            for i in 0..<out.area {
                let (x, y) = pixelXY(out, i)
                let k = Int(y - win.y0) * ww + Int(x - win.x0)
                let b = i * n
                switch model {
                case .gray: rp[b] = yv[k]
                case .lab: rp[b] = yv[k]; rp[b + 1] = c1[k]; rp[b + 2] = c2[k]
                case .ycc, .viaRGB:
                    let l = yv[k]
                    let bb = c1[k] + l, r = c2[k] + l
                    let g = (l - 0.299 * r - 0.114 * bb) / 0.587
                    if model == .ycc { rp[b] = r; rp[b + 1] = g; rp[b + 2] = bb }
                    else {
                        let a: Float = ctx.alpha ? rp[b + n - 1] : 1
                        ctx.setRGBA(UnsafeMutableBufferPointer(rebasing: rp[b..<(b + n)]), SIMD4(r, g, bb, a))
                    }
                }
            }
        }
        return res
    }

    struct Params: BitwiseCopyable {
        var model: UInt32
        var chan: UInt32
        var k: Float
        var eps: Float
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        if isIdentity || pass.srcRect.isEmpty { try pass.dispatchOut("pca_copy", params: NoParams()); return }
        let win = pass.srcRect
        let model = Self.model(pass.ctx.mode).rawValue
        let wf = pass.frame.with(src: win, out: win)
        var yc = try pass.texture(win)
        try pass.dispatch("pca_rn_decompose", frame: wf, params: Params(model: model, chan: 0, k: 0, eps: 0),
                          textures: [pass.src, yc], width: win.width, height: win.height)
        if removeJpegArtifact {
            let o = try pass.texture(win)
            try pass.dispatch("pca_rn_jpeg", frame: wf, params: NoParams(), textures: [yc, o], width: win.width, height: win.height)
            yc = o
        }
        func guided(chan: UInt32, r: Int, eps: Float, k: Float) throws {
            let m = try pass.texture(win)
            try pass.dispatch("pca_rn_moments", frame: wf, params: Params(model: model, chan: chan, k: 0, eps: 0),
                              textures: [yc, m], width: win.width, height: win.height)
            let mb = try pass.encodeBoxBlurN(m, rect: win, radius: r)
            let ab = try pass.texture(win)
            try pass.dispatch("pca_rn_ab", frame: wf, params: Params(model: model, chan: chan, k: 0, eps: eps),
                              textures: [mb, ab], width: win.width, height: win.height)
            let abb = try pass.encodeBoxBlurN(ab, rect: win, radius: r)
            let o = try pass.texture(win)
            try pass.dispatch("pca_rn_apply", frame: wf, params: Params(model: model, chan: chan, k: k, eps: 0),
                              textures: [yc, abb, o], width: win.width, height: win.height)
            yc = o
        }
        if s > 0 { try guided(chan: 0, r: lumaR, eps: lumaEps, k: s.squareRoot()) }
        if col > 0 && model != Model.gray.rawValue {
            try guided(chan: 1, r: chromaR, eps: chromaEps, k: col)
            try guided(chan: 2, r: chromaR, eps: chromaEps, k: col)
        }
        if sh > 0 {
            let bl = try pass.encodeGaussBlurN(yc, rect: win, sigma: 1)
            let o = try pass.texture(win)
            try pass.dispatch("pca_rn_sharpen", frame: wf, params: Params(model: model, chan: 0, k: sh * 1.2, eps: 0),
                              textures: [yc, bl, o], width: win.width, height: win.height)
            yc = o
        }
        try pass.dispatchOut("pca_rn_compose", params: Params(model: model, chan: 0, k: 0, eps: 0), textures: [pass.src, yc, pass.dst])
    }
}
