// Port of photocraft-compose (crates/compose/src/tests.rs helpers) and photocraft-gpu (parity tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Metal
import PCFoundation
@testable import PCRender

/// Deterministic xorshift PRNG.
struct Rng {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func float(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * float() }
}

enum TS {
    /// The shared Metal compositor (nil without Metal).
    static let metal: MetalCompositor? = try? MetalCompositor(chunkSize: 256)

    /// An RGBA8 surface over `rect` filled by `f(x, y)` (straight RGBA 0…1).
    static func surface(_ rect: PixelRect, format: PixelFormat = .rgba8, _ f: (Int32, Int32) -> SIMD4<Float>) -> Surface {
        var data: [Float] = []
        data.reserveCapacity(rect.area * format.channels)
        for y in rect.y0..<rect.y1 {
            for x in rect.x0..<rect.x1 {
                let p = f(x, y)
                for k in 0..<format.channels { data.append(k < 4 ? p[k] : 1) }
            }
        }
        var s = Surface(format: format)
        s.writeRegion(rect, data)
        return s
    }

    /// Random noisy RGBA with a soft disc of alpha (edges anti-aliased).
    static func blob(_ rect: PixelRect, seed: UInt64, cx: Float, cy: Float, r: Float, opaqueInside: Bool = true) -> Surface {
        var rng = Rng(seed)
        return surface(rect) { x, y in
            let d = ((Float(x) + 0.5 - cx) * (Float(x) + 0.5 - cx) + (Float(y) + 0.5 - cy) * (Float(y) + 0.5 - cy)).squareRoot()
            let a = min(max(r - d + 0.5, 0), 1)
            return SIMD4(rng.float(), rng.float(), rng.float(), opaqueInside ? a : a * rng.float(0.3, 1))
        }
    }

    /// Max channel difference and max difference in 8-bit levels (rounded) between two buffers.
    static func diff(_ a: RGBABuffer, _ b: RGBABuffer) -> (max: Float, levels: Int, at: Int) {
        precondition(a.rect == b.rect)
        var m: Float = 0, lv = 0, at = 0
        for i in a.px.indices {
            for c in 0..<4 {
                let d = abs(a.px[i][c] - b.px[i][c])
                if d.isNaN { if m.isFinite { m = .infinity; at = i }; lv = 255; continue }
                if d > m { m = d; at = i }
                let q = abs(Int((min(max(a.px[i][c], 0), 1) * 255).rounded()) - Int((min(max(b.px[i][c], 0), 1) * 255).rounded()))
                lv = max(lv, q)
            }
        }
        return (m, lv, at)
    }

    /// Premultiplied comparison (colour differences under low alpha don't count fully).
    static func diffPremul(_ a: RGBABuffer, _ b: RGBABuffer) -> Float {
        var m: Float = 0
        for i in a.px.indices {
            let p = a.px[i], q = b.px[i]
            let pa = SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w), qa = SIMD4(q.x * q.w, q.y * q.w, q.z * q.w, q.w)
            m = max(m, simd_reduce_max(simd_abs(pa - qa)))
        }
        return m
    }

    /// CPU and GPU renders of `plan` over `region` (GPU nil without Metal).
    static func both(_ plan: RenderPlan, _ region: PixelRect, _ source: any RenderSource, precision: AccumulatorPrecision = .float) throws -> (RGBABuffer, RGBABuffer?) {
        let cpu = try CPUCompositor(tileSize: 64).render(plan, region: region, source: source)
        guard let m = metal else { return (cpu, nil) }
        m.precision = precision
        let gpu = try m.renderBuffer(plan, region: region, source: source)
        return (cpu, gpu)
    }
}

import simd

import PCDocument

/// Labelled constructors for test fixtures (PCDocument uses payload structs).
extension Adjustment {
    static func brightnessContrast(brightness: Float, contrast: Float, legacy: Bool) -> Adjustment {
        .brightnessContrast(.init(brightness: brightness, contrast: contrast, legacy: legacy))
    }
    static func levels(master: LevelsChannel, perChannel: [LevelsChannel], space: ToneSpace, black: LevelsChannel) -> Adjustment {
        .levels(.init(master: master, perChannel: perChannel, space: space, black: black))
    }
    static func curves(master: [CurvePoint], perChannel: [[CurvePoint]], space: ToneSpace, black: [CurvePoint], pencil: Bool) -> Adjustment {
        .curves(.init(master: master, perChannel: perChannel, space: space, black: black, pencil: pencil))
    }
    static func exposure(exposure: Float, offset: Float, gamma: Float) -> Adjustment { .exposure(.init(exposure: exposure, offset: offset, gamma: gamma)) }
    static func vibrance(vibrance: Float, saturation: Float) -> Adjustment { .vibrance(.init(vibrance: vibrance, saturation: saturation)) }
    static func hueSaturation(hue: Float, saturation: Float, lightness: Float, colorize: Bool, ranges: [HueRange]) -> Adjustment {
        .hueSaturation(.init(hue: hue, saturation: saturation, lightness: lightness, colorize: colorize, ranges: ranges))
    }
    static func colorBalance(shadows: SIMD3<Float>, midtones: SIMD3<Float>, highlights: SIMD3<Float>, preserveLuminosity: Bool) -> Adjustment {
        .colorBalance(.init(shadows: shadows, midtones: midtones, highlights: highlights, preserveLuminosity: preserveLuminosity))
    }
    static func blackWhite(weights: [Float], tint: SIMD3<Float>?) -> Adjustment { .blackWhite(.init(weights: weights, tint: tint)) }
    static func photoFilter(color: SIMD3<Float>, density: Float, preserveLuminosity: Bool) -> Adjustment {
        .photoFilter(.init(color: color, density: density, preserveLuminosity: preserveLuminosity))
    }
    static func channelMixer(matrix: [SIMD4<Float>], monochrome: Bool) -> Adjustment { .channelMixer(.init(matrix: matrix, monochrome: monochrome)) }
    static func colorLookup(name: String, lut: [Float]?, size: UInt32, tetrahedral: Bool, dither: Bool) -> Adjustment {
        .colorLookup(.init(name: name, lut: lut, size: size, tetrahedral: tetrahedral, dither: dither))
    }
    static func gradientMap(stops: [GradientMapStop], reverse: Bool, dither: Bool) -> Adjustment { .gradientMap(.init(stops: stops, reverse: reverse, dither: dither)) }
    static func selectiveColor(relative: Bool, adjustments: [SIMD4<Float>]) -> Adjustment { .selectiveColor(.init(relative: relative, adjustments: adjustments)) }
}

extension LevelsChannel {
    static let identity = LevelsChannel()
}
