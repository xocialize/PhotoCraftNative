// Port of photocraft-algo (crates/algo/src/paint.rs: the gradient tool), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Gradient tool: a parameter t per pixel (linear, radial, angle, reflected, diamond) sampled
// through RGBA stops, optionally dithered by one 8-bit step of position noise, and composited with
// a blend mode at `opacity × selection` over the surface (in straight sRGB, converted to and from
// the surface's model). The Metal path composites with foundation's `pc_composite`.

import Foundation
import Metal
import PCFoundation

/// Gradient tool shape.
public enum GradientShape: String, Codable, Sendable, Hashable, CaseIterable { case linear, radial, angle, reflected, diamond }

public enum GradientTool {
    /// photocraft `tool_gradient_t` for a drag from `from` to `to` at (x, y).
    public static func t(_ shape: GradientShape, from: SIMD2<Float>, to: SIMD2<Float>, x: Float, y: Float) -> Float {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = max((dx * dx + dy * dy).squareRoot(), 1e-6)
        let ux = dx / len, uy = dy / len
        let px = x - from.x, py = y - from.y
        let along = px * ux + py * uy
        let across = -px * uy + py * ux
        let t: Float
        switch shape {
        case .linear: t = along / len
        case .radial: t = (px * px + py * py).squareRoot() / len
        case .reflected: t = abs(along) / len
        case .diamond: t = (abs(along) + abs(across)) / len
        case .angle: t = euclidMod(atan2f(across, along) / PCAMath.tau, 1)
        }
        return clampf(t, 0, 1)
    }

    /// photocraft `sample_stops`: RGBA stops sorted by position.
    public static func sample(_ stops: [(Float, SIMD4<Float>)], _ t: Float) -> SIMD4<Float> {
        if stops.isEmpty { return .zero }
        if stops.count == 1 { return stops[0].1 }
        if t <= stops[0].0 { return stops[0].1 }
        for i in 1..<stops.count {
            let a = stops[i - 1], b = stops[i]
            if t <= b.0 {
                let k: Float = b.0 > a.0 ? (t - a.0) / (b.0 - a.0) : 0
                return a.1 + (b.1 - a.1) * k
            }
        }
        return stops[stops.count - 1].1
    }

    /// The gradient's colour at pixel (x, y).
    static func colour(_ shape: GradientShape, _ from: SIMD2<Float>, _ to: SIMD2<Float>, _ stops: [(Float, SIMD4<Float>)],
                       _ reverse: Bool, _ dither: Bool, _ x: Int32, _ y: Int32) -> SIMD4<Float> {
        let tt = t(shape, from: from, to: to, x: Float(x) + 0.5, y: Float(y) + 0.5)
        var c = sample(stops, reverse ? 1 - tt : tt)
        if dither {
            let n = (ColorConvert.ditherNoise(x: x, y: y) - 0.5) / 255
            for k in 0..<3 { c[k] = clampf(c[k] + n, 0, 1) }
        }
        return c
    }

    /// Paints the gradient over `area` of `surface` (photocraft `paint_gradient`). The Metal path
    /// runs for Gray- and RGB-like surfaces; others composite on the CPU (ColorSync conversion).
    public static func paint(_ surface: inout Surface, area: PixelRect, from: SIMD2<Float>, to: SIMD2<Float>, shape: GradientShape,
                             stops: [(Float, SIMD4<Float>)], reverse: Bool = false, opacity: Float = 1, blendMode: BlendMode = .normal,
                             dither: Bool = false, selection: Surface? = nil, lockTransparency: Bool = false, on backend: Backend = .auto) throws {
        if area.isEmpty { return }
        let fmt = surface.format
        let ctx = FilterContext(bounds: area, format: fmt)
        let n = fmt.channels
        let img = FloatImage(surface: surface, rect: area)
        let cov: [Float] = selection.map { sel in
            let raw = sel.readRegion(area)
            return (0..<area.area).map { opacity * raw[$0 * sel.channels] }
        } ?? [Float](repeating: opacity, count: area.area)
        let gpuOK = (fmt.mode.isGrayLike || fmt.mode.isRGBLike) && ctx.colorChannels(n) <= 3
            && blendMode != .dissolve && blendMode != .passThrough
        var out: FloatImage
        if backend != .cpu, gpuOK, let gpu = try? AlgoGPU.shared() {
            out = try paintGPU(gpu, img, ctx, cov, shape, from, to, stops, reverse, dither, blendMode, lockTransparency)
        } else {
            if backend == .gpu { throw FilterError.gpuUnsupported("Gradient for \(fmt.mode)\(fmt.alpha ? "+alpha" : "") / \(blendMode)") }
            out = img
            out.data.withUnsafeMutableBufferPointer { ob in
                let os = UnsafeSendable(ob)
                parallelChunks(area.height, minChunk: 8) { rows in
                    for oy in rows {
                        for ox in 0..<area.width {
                            let i = oy * area.width + ox
                            let k = cov[i]
                            if k <= 0 { continue }
                            let x = area.x0 + Int32(ox), y = area.y0 + Int32(oy)
                            let px = UnsafeMutableBufferPointer(rebasing: os.value[(i * n)..<(i * n + n)])
                            let d = ctx.rgba(UnsafeBufferPointer(px))
                            var o = Blend.composite(blendMode, backdrop: d, source: colour(shape, from, to, stops, reverse, dither, x, y), opacity: k)
                            if lockTransparency { o.w = d.w }
                            ctx.setRGBA(px, o)
                        }
                    }
                }
            }
        }
        surface.writeRegion(area, out.data)
    }

    struct Params: BitwiseCopyable {
        var from: SIMD2<Float>
        var to: SIMD2<Float>
        var shape: UInt32
        var stops: Int32
        var reverse: UInt32
        var dither: UInt32
        var mode: UInt32
        var lock: UInt32
        var gray: UInt32
        var pad: UInt32 = 0
    }

    static func paintGPU(_ gpu: AlgoGPU, _ img: FloatImage, _ ctx: FilterContext, _ cov: [Float], _ shape: GradientShape,
                         _ from: SIMD2<Float>, _ to: SIMD2<Float>, _ stops: [(Float, SIMD4<Float>)], _ reverse: Bool, _ dither: Bool,
                         _ mode: BlendMode, _ lock: Bool) throws -> FloatImage {
        let shapeCode = UInt32(GradientShape.allCases.firstIndex(of: shape)!)
        let p = Params(from: from, to: to, shape: shapeCode, stops: Int32(stops.count), reverse: reverse ? 1 : 0, dither: dither ? 1 : 0,
                       mode: mode.rawValue, lock: lock ? 1 : 0, gray: ctx.mode.isGrayLike ? 1 : 0)
        let pos = stops.map { SIMD4<Float>($0.0, 0, 0, 0) }, col = stops.map(\.1)
        let probe = GradientProbe(params: p, positions: pos, colours: col, coverage: cov)
        return try FilterEngine.apply(probe, to: img, output: img.rect, context: ctx, on: .gpu)
    }
}

/// The gradient composite as an internal filter (one pass over the area, coverage inside).
struct GradientProbe: Filter {
    var params: GradientTool.Params
    var positions: [SIMD4<Float>]
    var colours: [SIMD4<Float>]
    var coverage: [Float]
    var label: String { "Gradient" }
    func halo(bounds: PixelRect) -> Halo { .radius(0) }
    func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage { src.crop(out) }
    func encodeGPU(_ pass: GPUPass) throws {
        try pass.dispatchOut("pca_misc_gradient", params: params, buffers: [try pass.buffer(positions.isEmpty ? [SIMD4<Float>.zero] : positions),
                                                                            try pass.buffer(colours.isEmpty ? [SIMD4<Float>.zero] : colours),
                                                                            try pass.buffer(coverage)])
    }
    enum CodingKeys: CodingKey {}
    init(params: GradientTool.Params, positions: [SIMD4<Float>], colours: [SIMD4<Float>], coverage: [Float]) {
        self.params = params; self.positions = positions; self.colours = colours; self.coverage = coverage
    }
    init(from decoder: any Decoder) throws { throw FilterError.invalidInput("not decodable") }
    func encode(to encoder: any Encoder) throws {}
}
