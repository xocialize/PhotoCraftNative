// Port of photocraft-gpu (crates/gpu/src/plan.rs `adjustment_program`, `adjustment_on_gpu`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// An adjustment as the `pcr_adjust` kernel takes it: the specialisation kind, parameters in
// op.p0…p3 and its tables (tone LUT rows, hue-range tables, stops, records, 3D LUT) in one buffer —
// built from the same `PreparedAdjustment` tables the CPU reference uses, so LUT-driven adjustments
// match bit for bit. Unlike photocraft-gpu, Lab-channel adjustments and Lab / naive-CMYK tone spaces
// run on the GPU too; only CMYK tone spaces through a managed (ColorSync) converter stay on the CPU.

import Foundation
import Metal
import PCDocument
import PCFoundation

struct GPUAdjustment {
    let kind: UInt32
    var p = [SIMD4<Float>](repeating: .zero, count: 4)
    let buffer: any MTLBuffer

    /// Whether `adj` must be evaluated on the CPU (`MetalCompositor.unsupportedReason`).
    static func needsCPU(_ adj: Adjustment, _ ctx: RenderContext) -> Bool {
        guard ColorConvert.cmyk != nil else { return false }
        switch adj {
        case .levels, .curves: return adj.toneSpace == .cmyk
        default: return false
        }
    }

    func fill(_ op: inout PCROp) {
        op.p0 = p[0]; op.p1 = p[1]; op.p2 = p[2]; op.p3 = p[3]
    }

    init(_ adj: Adjustment, _ ctx: RenderContext, kernels: PCRKernels) {
        let prep = PreparedAdjustment(adj, transfer: ctx.transfer, depth: ctx.depth, mode: ctx.mode)
        var p = [SIMD4<Float>](repeating: .zero, count: 4)
        var data: [Float] = []
        var kind: UInt32 = 0
        func rows(_ r: [[Float]]) { for row in r { data.append(contentsOf: row) } }
        if prep.lab {
            switch adj {
            case .invert: kind = 20
            case .posterize(let levels): kind = 21; p[0].x = Float(min(max(levels, 2), 255))
            case .threshold(let level): kind = 22; p[0].x = (level * 255).rounded()
            case .brightnessContrast(let bc):
                let (b, c, legacy) = (bc.brightness, bc.contrast, bc.legacy)
                kind = 23
                let l = AdjustMath.legacyBrightnessContrast(b, c)
                p[0] = SIMD4(l.pre, l.k, AdjustMath.legacyPivot, l.post)
                p[1] = SIMD4(b, c, 0, 0)
                p[2].x = legacy ? 1 : 0
                if !legacy { rows([prep.luts[0]]) }
            case .gradientMap(let gm):
                let (stops, reverse, dither) = (gm.stops, gm.reverse, gm.dither)
                kind = 24
                p[0] = SIMD4(reverse ? 1 : 0, dither ? 1 : 0, Float(stops.count), 0)
                for s in stops { data.append(contentsOf: [s.location, s.rgb.x, s.rgb.y, s.rgb.z]) }
            default: break
            }
        } else {
            switch adj {
            case .invert: kind = 1
            case .threshold(let level): kind = 2; p[0].x = (level * 255).rounded()
            case .posterize(let levels): kind = 3; p[0].x = Float(min(max(levels, 2), 255))
            case .brightnessContrast(let bc) where bc.legacy:
                let (b, c) = (bc.brightness, bc.contrast)
                kind = 4
                let l = AdjustMath.legacyBrightnessContrast(b, c)
                p[0] = SIMD4(l.pre, l.k, AdjustMath.legacyPivot, l.post)
            case .brightnessContrast(let bc):
                // Modern, and Light on CMYK ink planes: the curve per channel (kind 7). Light: four
                // stages through ProPhoto (kind 5: the stage LUTs, ProPhoto ← sRGB rows, sRGB ←
                // ProPhoto rows; p0 = each stage's `AdjustMath.LightStageMode`).
                if bc.mode == .modern || ctx.native == .cmykInk || ctx.native == .cmykBlack {
                    kind = 7
                    rows(Array(repeating: prep.luts[0], count: 3))
                } else {
                    kind = 5
                    rows(Array(prep.luts[1...4]))
                    for r in AdjustMath.proPhotoFromSRGB + AdjustMath.srgbFromProPhoto { data.append(contentsOf: [r.x, r.y, r.z]) }
                    let m = prep.lightModes
                    p[0] = SIMD4(Float(m.x), Float(m.y), Float(m.z), Float(m.w))
                }
            case .exposure(let ex):
                let (exposure, offset, gamma) = (ex.exposure, ex.offset, ex.gamma)
                kind = 6
                p[0] = SIMD4(powf(2, exposure), offset, max(gamma, 0.01), ctx.transfer.forExposure.exponent)
            case .levels(let lv) where lv.space == .rgb && ctx.depth == .f32:
                let (master, perChannel) = (lv.master, lv.perChannel)
                kind = 8
                let pc = perChannel.count >= 3 ? perChannel : [LevelsChannel(), LevelsChannel(), LevelsChannel()]
                for r in [master] + pc { data.append(contentsOf: [r.inBlack, r.inWhite, r.gamma, r.outBlack, r.outWhite]) }
                p[0] = SIMD4(master.isIdentity ? 1 : 0, pc[0].isIdentity ? 1 : 0, pc[1].isIdentity ? 1 : 0, pc[2].isIdentity ? 1 : 0)
            case .levels, .curves:
                switch adj.toneSpace {
                case .rgb:
                    kind = 7
                    rows(Array(prep.luts.prefix(3)))
                    p[0] = SIMD4(prep.identity[0] ? 1 : 0, prep.identity[1] ? 1 : 0, prep.identity[2] ? 1 : 0, 0)
                case .lab: kind = 9; rows(Array(prep.luts.prefix(3)))
                case .cmyk: kind = 10; rows(prep.luts)
                }
            case .hueSaturation(let hs):
                let (hue, saturation, lightness, colorize) = (hs.hue, hs.saturation, hs.lightness, hs.colorize)
                kind = 11
                p[0] = SIMD4(hue, saturation / 100, lightness / 100, colorize ? 1 : 0)
                if !prep.luts.isEmpty { p[1].x = 1; rows(prep.luts) }
            case .vibrance(let vb):
                let (v, s) = (vb.vibrance, vb.saturation)
                kind = 12
                p[0] = SIMD4(v / 100, s / 100, ctx.transfer.exponent, ctx.depth == .f32 ? .greatestFiniteMagnitude : 1)
            case .channelMixer(let cm):
                let (matrix, monochrome) = (cm.matrix, cm.monochrome)
                kind = 13
                let m = matrix.count >= 3 ? matrix : [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)]
                p[0] = m[0]; p[1] = m[1]; p[2] = m[2]; p[3].x = monochrome ? 1 : 0
            case .photoFilter(let pf):
                let preserve = pf.preserveLuminosity
                kind = 14
                let m = prep.photoMatrix
                p[0] = SIMD4(m[0], 0); p[1] = SIMD4(m[1], 0); p[2] = SIMD4(m[2], 0)
                p[3] = SIMD4(preserve && ctx.depth != .f32 ? 1 : 0, ctx.transfer.exponent, 0, 0)
            case .blackWhite(let bw):
                let (weights, tint) = (bw.weights, bw.tint)
                kind = 15
                let w = weights.count >= 6 ? weights : [40, 60, 40, 60, 20, 80]
                p[0] = SIMD4(w[0], w[1], w[2], w[3])
                p[1] = SIMD4(w[4], w[5], tint == nil ? 0 : 1, 0)
                if let t = tint { p[2] = SIMD4(t, 0) }
            case .gradientMap(let gm):
                let (stops, reverse, dither) = (gm.stops, gm.reverse, gm.dither)
                kind = 16
                p[0] = SIMD4(reverse ? 1 : 0, dither ? 1 : 0, Float(stops.count), 0)
                for s in stops { data.append(contentsOf: [s.location, s.rgb.x, s.rgb.y, s.rgb.z]) }
            case .colorBalance(let cbal):
                let (s, m, h, preserve) = (cbal.shadows, cbal.midtones, cbal.highlights, cbal.preserveLuminosity)
                kind = 17
                p[0] = SIMD4(s, 0); p[1] = SIMD4(m, 0); p[2] = SIMD4(h, 0); p[3].x = preserve ? 1 : 0
            case .selectiveColor(let sc):
                let (relative, adjustments) = (sc.relative, sc.adjustments)
                kind = 18
                p[0].x = relative ? 1 : 0
                p[0].y = AdjustMath.grayMode(ctx.mode) ? 1 : 0
                for i in 0..<9 { let a = i < adjustments.count ? adjustments[i] : .zero; data.append(contentsOf: [a.x, a.y, a.z, a.w]) }
            case .colorLookup(let cl) where cl.lut != nil:
                let (table, size, tetrahedral, dither) = (cl.lut!, cl.size, cl.tetrahedral, cl.dither)
                if let len = lut3DLength(size), table.count >= len {
                    kind = 19
                    p[0] = SIMD4(Float(size), tetrahedral ? 1 : 0, dither ? 1 : 0, 0)
                    data = Array(table.prefix(len))
                }
            // Filter adjustments are planned as `.filter` / `.backdropFilter` ops, never `.adjust`.
            case .colorLookup, .unsupported, .filter: kind = 0
            }
        }
        self.kind = kind
        self.p = p
        self.buffer = kernels.buffer(data.isEmpty ? [Float(0)] : data)!
    }
}
