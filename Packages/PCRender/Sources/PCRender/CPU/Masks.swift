// Port of photocraft-compose (crates/compose/src/masks.rs, lib.rs `mask_vals`) and photocraft-gpu (compose.wgsl `mask_value`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Reading leaves on the CPU, and a layer's effective mask: the pixel mask with density times the
// vector-mask coverage, each blurred by its feather. A feathered mask blurs across tiles, so it is
// built once over the canvas (`combined_mask`) and stored at 16 bits, as photocraft's mask cache
// does. Pixel-mask feathers are three clamped box passes per axis (photocraft's approximation of a
// Gaussian of sigma = feather, which matches Photoshop); vector-mask feathers are an exact
// Gaussian of sigma = feather (what Photoshop does there; photocraft uses the box passes for both).

import Foundation
import PCDocument
import PCFoundation

enum LeafReader {
    /// Straight RGBA of `leaf` over `rect`.
    static func rgba(_ leaf: RenderLeaf, _ rect: PixelRect) -> [SIMD4<Float>] {
        switch leaf {
        case .surface(let s):
            return s.readRGBA(rect)
        case let .image(img, outside, _):
            var out = [SIMD4<Float>](repeating: outside, count: rect.area)
            let inter = img.rect.intersect(rect)
            if inter.isEmpty { return out }
            let ch = img.channels
            img.data.withUnsafeBufferPointer { d in
                for y in inter.y0..<inter.y1 {
                    for x in inter.x0..<inter.x1 {
                        let s = img.index(x: x, y: y)
                        let o = Int(y - rect.y0) * rect.width + Int(x - rect.x0)
                        switch ch {
                        case 1: out[o] = SIMD4(d[s], d[s], d[s], 1)
                        case 2: out[o] = SIMD4(d[s], d[s], d[s], d[s + 1])
                        case 3: out[o] = SIMD4(d[s], d[s + 1], d[s + 2], 1)
                        default: out[o] = SIMD4(d[s], d[s + 1], d[s + 2], d[s + 3])
                        }
                    }
                }
            }
            return out
        }
    }

    /// Channel 0 of `leaf` over `rect` (masks, coverage, shapes).
    static func values(_ leaf: RenderLeaf, _ rect: PixelRect) -> [Float] {
        switch leaf {
        case .surface(let s):
            if s.channels == 1 { return s.readRegion(rect) }
            let raw = s.readRegion(rect), ch = s.channels
            return (0..<rect.area).map { raw[$0 * ch] }
        case let .image(img, outside, _):
            var out = [Float](repeating: outside.x, count: rect.area)
            let inter = img.rect.intersect(rect)
            if inter.isEmpty { return out }
            for y in inter.y0..<inter.y1 {
                for x in inter.x0..<inter.x1 {
                    out[Int(y - rect.y0) * rect.width + Int(x - rect.x0)] = img.data[img.index(x: x, y: y)]
                }
            }
            return out
        }
    }

    /// Default (outside) value of a mask / coverage leaf.
    static func outsideValue(_ leaf: RenderLeaf) -> Float {
        switch leaf {
        case .surface(let s): s.defaultPixelValue.first ?? 0
        case .image(_, let outside, _): outside.x
        }
    }

    /// Where a mask / coverage leaf can differ from its outside value.
    static func extent(_ leaf: RenderLeaf) -> PixelRect {
        switch leaf {
        case .surface(let s): ContentBounds.of(s)
        case .image(let img, _, _): img.rect
        }
    }

    /// Identity of a leaf's pixels (tile generations or the image version).
    static func version(_ leaf: RenderLeaf) -> UInt64 {
        switch leaf {
        case .surface(let s): return ContentBounds.fingerprint(s)
        case .image(_, _, let v): return v
        }
    }
}

/// A feathered (or otherwise canvas-wide) mask: values over `area`, `outside` elsewhere.
struct CombinedMask: Sendable {
    let area: PixelRect
    let values: [Float]
    let outside: Float

    func read(_ rect: PixelRect) -> [Float] {
        var out = [Float](repeating: outside, count: rect.area)
        let inter = area.intersect(rect)
        if inter.isEmpty { return out }
        for y in inter.y0..<inter.y1 {
            let s = Int(y - area.y0) * area.width + Int(inter.x0 - area.x0)
            let d = Int(y - rect.y0) * rect.width + Int(inter.x0 - rect.x0)
            for k in 0..<inter.width { out[d + k] = values[s + k] }
        }
        return out
    }
}

enum MaskMath {
    /// Box radius of the three-pass Gaussian of `sigma` (Wells 1986).
    static func gaussianRadius(_ sigma: Float) -> Int {
        if sigma <= 0 { return 0 }
        let ideal = (12 * sigma * sigma / 3 + 1).squareRoot()
        return ((Int(ideal.rounded(.down)) | 1) - 1) / 2
    }

    /// One clamped box pass of radius `r` over a line (running f32 sum, as photocraft).
    static func blurLine(_ line: UnsafeMutableBufferPointer<Float>, _ scratch: UnsafeMutableBufferPointer<Float>, _ r: Int) {
        let n = line.count
        if n == 0 { return }
        for i in 0..<n { scratch[i] = line[i] }
        @inline(__always) func get(_ i: Int) -> Float { scratch[min(max(i, 0), n - 1)] }
        var acc: Float = 0
        for i in -r...r { acc += get(i) }
        let cnt = Float(2 * r + 1)
        for i in 0..<n {
            line[i] = acc / cnt
            acc += get(i + r + 1) - get(i - r)
        }
    }

    /// Three clamped box passes per axis (an approximate Gaussian of `sigma`).
    static func gaussian(_ v: inout [Float], _ w: Int, _ h: Int, _ sigma: Float) {
        let r = gaussianRadius(sigma)
        if r == 0 || w == 0 || h == 0 || v.count != w * h { return }
        func rows(_ buf: inout [Float], _ lw: Int, _ lh: Int) {
            buf.withUnsafeMutableBufferPointer { p in
                let P = UnsafeSendable(p)
                parallelChunks(lh, work: lw * lh) { range in
                    let scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: lw)
                    defer { scratch.deallocate() }
                    for y in range {
                        let line = UnsafeMutableBufferPointer(rebasing: P.value[(y * lw)..<(y * lw + lw)])
                        for _ in 0..<3 { blurLine(line, scratch, r) }
                    }
                }
            }
        }
        rows(&v, w, h)
        var t = EffectMath.transpose(v, w, h)
        rows(&t, h, w)
        v = EffectMath.transpose(t, h, w)
    }

    /// Weights of the exact Gaussian a vector-mask feather of `sigma` blurs with (radius ⌈3σ⌉,
    /// normalised).
    static func gaussianWeights(_ sigma: Float) -> [Float] {
        if !(sigma > 0) { return [1] }
        let r = Int((sigma * 3).rounded(.up))
        let k = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let s = k.reduce(0, +)
        return k.map { $0 / s }
    }

    /// An exact separable Gaussian with clamped edges. Photoshop feathers vector masks this way
    /// (ps-corpus mask-vector-feather: sigma = feather, mean 0.22 levels; the three-box
    /// approximation pixel masks match is 3.5 px wide for a 3 px feather: 39 % of pixels off).
    static func exactGaussian(_ v: inout [Float], _ w: Int, _ h: Int, _ sigma: Float) {
        if !(sigma > 0) || w == 0 || h == 0 || v.count != w * h { return }
        let k = gaussianWeights(sigma)
        let r = k.count / 2
        func rows(_ buf: inout [Float], _ lw: Int, _ lh: Int) {
            let src = buf
            buf.withUnsafeMutableBufferPointer { p in
                let P = UnsafeSendable(p)
                src.withUnsafeBufferPointer { sp in
                    let S = UnsafeSendable(sp)
                    parallelChunks(lh, work: lw * lh * (2 * r + 1)) { range in
                        for y in range {
                            let row = y * lw
                            for x in 0..<lw {
                                var a: Float = 0
                                for j in -r...r { a += k[j + r] * S.value[row + min(max(x + j, 0), lw - 1)] }
                                P.value[row + x] = a
                            }
                        }
                    }
                }
            }
        }
        rows(&v, w, h)
        var t = EffectMath.transpose(v, w, h)
        rows(&t, h, w)
        v = EffectMath.transpose(t, h, w)
    }

    /// Rounds to the 16-bit mask format's levels.
    @inline(__always) static func q16(_ v: Float) -> Float {
        Float(UInt16(min(max(v, 0), 1) * 65535 + 0.5)) / 65535
    }

    /// `masks::build_mask` over leaves: the combined, feathered mask over `canvas`.
    static func buildCombined(_ spec: MaskSpec, pixel: RenderLeaf?, vector: RenderLeaf?, canvas: PixelRect) -> CombinedMask {
        let sv = vector == nil ? 0 : MaskSpec.featherSigma(spec.vectorFeather)
        let sp = pixel == nil ? 0 : MaskSpec.featherSigma(spec.feather)
        let vOut: Float = vector.map(LeafReader.outsideValue) ?? 1
        let pDef: Float = pixel.map { 1 - spec.density * (1 - LeafReader.outsideValue($0)) } ?? 1
        func grow(_ r: PixelRect, _ sigma: Float) -> PixelRect { r.isEmpty ? r : r.outset(by: Int32((sigma * 3).rounded(.up)) + 2) }
        var area = vector.map { grow(LeafReader.extent($0), sv) } ?? .empty
        if let p = pixel, vOut > 0 {
            area = area.union(grow(LeafReader.extent(p), sp))
        }
        area = area.intersect(canvas)
        let outside = q16(pDef * vOut)
        if area.isEmpty { return CombinedMask(area: .empty, values: [], outside: outside) }
        let (w, h) = (area.width, area.height)
        var v = vector.map { LeafReader.values($0, area) } ?? [Float](repeating: 1, count: w * h)
        exactGaussian(&v, w, h, sv)
        if let p = pixel {
            var pm = LeafReader.values(p, area)
            if spec.density < 1 { for i in pm.indices { pm[i] = 1 - spec.density * (1 - pm[i]) } }
            gaussian(&pm, w, h, sp)
            for i in v.indices { v[i] *= pm[i] }
        }
        return CombinedMask(area: area, values: v.map(q16), outside: outside)
    }
}

enum BlendIfMath {
    /// How much of a pixel shows through Blend If (`blend_if_weight`, refitted to Photoshop: the
    /// gray value is 0.30 R + 0.59 G + 0.11 B, rounded to a level in 8-bit documents, and a split
    /// slider ramps over `hi − lo + 1` levels starting one level below `lo` — see `rangeWeight`).
    static func weight(_ bi: BlendIf, rgbMode: Bool, this: SIMD4<Float>?, under: SIMD4<Float>?, ps8: Bool = false) -> Float {
        var k: Float = 1
        for (side, px) in [(0, this), (1, under)] {
            guard let p = px else { continue }
            func v(_ c: Int) -> Float { let x = min(max(p[c], 0), 1) * 255; return ps8 ? x.rounded() : x }
            func range(_ i: Int) -> BlendRange { side == 0 ? bi.get(i).this : bi.get(i).underlying }
            if rgbMode {
                var gray = 0.30 * v(0) + 0.59 * v(1) + 0.11 * v(2)
                if ps8 { gray = gray.rounded() }
                k *= rangeWeight(range(0), gray)
                for c in 0..<3 { k *= rangeWeight(range(c + 1), v(c)) }
            } else {
                k *= rangeWeight(range(0), v(0)) * rangeWeight(range(1), v(0))
            }
            if k <= 0 { return 0 }
        }
        return k
    }

    /// `BlendRange.weight` as Photoshop draws it (blendif-gray: 0.03 % of pixels off against
    /// 9 % with PCDocument's ramp). A split black point (lo, hi) shows (v − lo + 1) / (hi − lo + 1),
    /// a split white point mirrors it; unsplit points are the same steps as `BlendRange.weight`.
    @inline(__always) static func rangeWeight(_ r: BlendRange, _ v: Float) -> Float {
        @inline(__always) func ramp(_ lo: Float, _ hi: Float, _ x: Float) -> Float {
            if hi <= lo { return x >= lo ? 1 : 0 }
            return min(max((x - lo + 1) / (hi - lo + 1), 0), 1)
        }
        return ramp(Float(r.black[0]), Float(r.black[1]), v) * ramp(255 - Float(r.white[1]), 255 - Float(r.white[0]), 255 - v)
    }
}
