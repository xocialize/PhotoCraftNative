// Port of photocraft-algo (crates/algo/src/tone.rs: `replace_color`, `lab_stats`, `match_color`, `hdr_toning`; selection.rs `color_range`; other2.rs `rgb_to_hsl`, `hsl_to_rgb`; fxutil.rs `gauss_blur_n`, `gauss_box_radii`, box passes), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Part of the adjust_cmds port: the CPU reference of the destructive tone adjustments the engine
// runs itself — Replace Color, Match Color and HDR Toning — ported locally because they are small
// (Shadows/Highlights, photocraft's measured 300-line model, is PCAlgo's ToneKit: see
// `AdjustCommands+ShadowsHighlights.swift`).
//
// All work on straight (non-premultiplied) RGBA buffers, row-major `w × h`, so callers convert any
// colour model / bit depth to RGBA first. Formulas are photocraft's documented approximations of
// Photoshop's behaviour.

import Foundation
import PCFoundation

extension AdjustCommands {
    enum ToneKit {
        static func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

        /// Rust `f32::rem_euclid`.
        static func remEuclid(_ x: Float, _ m: Float) -> Float {
            let r = x.truncatingRemainder(dividingBy: m)
            return r < 0 ? r + abs(m) : r
        }

        @inline(__always) static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { Swift.min(Swift.max(x, lo), hi) }

        // MARK: Colour models

        static func rgbToHsl(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let mx = Swift.max(Swift.max(c.x, c.y), c.z), mn = Swift.min(Swift.min(c.x, c.y), c.z)
            let d = mx - mn
            let l = (mx + mn) / 2
            let s: Float = d <= 0 ? 0 : d / Swift.max(1 - abs(2 * l - 1), 1e-7)
            return SIMD3(hue(c, mx, d), clamp(s, 0, 1), l)
        }

        static func hue(_ c: SIMD3<Float>, _ mx: Float, _ d: Float) -> Float {
            if d <= 0 { return 0 }
            let h: Float
            if mx == c.x {
                h = remEuclid((c.y - c.z) / d, 6)
            } else if mx == c.y {
                h = (c.z - c.x) / d + 2
            } else {
                h = (c.x - c.y) / d + 4
            }
            return h / 6
        }

        /// RGB from hue, chroma and the value to add.
        static func fromHcm(_ h: Float, _ chroma: Float, _ m: Float) -> SIMD3<Float> {
            let hp = remEuclid(h, 1) * 6
            let x = chroma * (1 - abs(remEuclid(hp, 2) - 1))
            let sector = hp.isFinite ? Int(Swift.max(Swift.min(hp, 1e9), -1e9)) : 0
            let rgb: SIMD3<Float>
            switch sector {
            case 0: rgb = SIMD3(chroma, x, 0)
            case 1: rgb = SIMD3(x, chroma, 0)
            case 2: rgb = SIMD3(0, chroma, x)
            case 3: rgb = SIMD3(0, x, chroma)
            case 4: rgb = SIMD3(x, 0, chroma)
            default: rgb = SIMD3(chroma, 0, x)
            }
            return rgb + SIMD3(repeating: m)
        }

        static func hslToRgb(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let chroma = (1 - abs(2 * c.z - 1)) * c.y
            return fromHcm(c.x, chroma, c.z - chroma / 2)
        }

        // MARK: Replace Color

        /// Select › Color Range (Sampled Colors) for one colour: `fuzziness` in levels.
        static func colorRange(_ px: [SIMD4<Float>], _ color: SIMD3<Float>, _ fuzziness: Float) -> [Float] {
            let f = Swift.max(fuzziness, 0) + 1
            return px.map { p in
                if p.w <= 0 { return 0 }
                let d = Swift.max(Swift.max(abs(p.x - color.x) * 255, abs(p.y - color.y) * 255), abs(p.z - color.z) * 255)
                return clamp(1 - d / f, 0, 1)
            }
        }

        /// Image › Adjustments › Replace Color: Color Range-style selection (fuzziness in 0...200
        /// levels) around `color`, then a hue (±180°), saturation and lightness (±100) shift
        /// weighted by it. Returns the selection mask (what the dialog previews).
        @discardableResult
        static func replaceColor(_ px: inout [SIMD4<Float>], _ color: SIMD3<Float>, _ fuzziness: Float, _ hue: Float, _ saturation: Float, _ lightness: Float) -> [Float] {
            let mask = colorRange(px, color, fuzziness)
            for i in px.indices {
                let k = mask[i]
                if k <= 0 { continue }
                let c = SIMD3(px[i].x, px[i].y, px[i].z)
                let hsl = rgbToHsl(c)
                let s = saturation >= 0 ? hsl.y + (1 - hsl.y) * saturation / 100 : hsl.y * (1 + saturation / 100)
                let l = lightness >= 0 ? hsl.z + (1 - hsl.z) * lightness / 100 : hsl.z * (1 + lightness / 100)
                let o = hslToRgb(SIMD3(remEuclid(hsl.x + hue / 360, 1), clamp(s, 0, 1), clamp(l, 0, 1)))
                px[i].x = clamp(c.x + (o.x - c.x) * k, 0, 1)
                px[i].y = clamp(c.y + (o.y - c.y) * k, 0, 1)
                px[i].z = clamp(c.z + (o.z - c.z) * k, 0, 1)
            }
            return mask
        }

        // MARK: Match Color

        /// Lab mean and standard deviation of the opaque pixels, `[L, a, b]` each.
        struct LabStats: Equatable {
            var mean: SIMD3<Float>
            var std: SIMD3<Float>
        }

        /// Statistics for Match Color (pixels weighted by alpha × optional mask).
        static func labStats(_ px: [SIMD4<Float>], _ mask: [Float]?) -> LabStats? {
            var sum = SIMD3<Double>(), sq = SIMD3<Double>()
            var wsum = 0.0
            for (i, q) in px.enumerated() {
                let m: Float = mask.map { i < $0.count ? $0[i] : 0 } ?? 1
                let w = Double(q.w * m)
                if !(w > 0) { continue }
                let lab = ColorConvert.srgbToLab(SIMD3(q.x, q.y, q.z))
                for k in 0..<3 {
                    sum[k] += w * Double(lab[k])
                    sq[k] += w * Double(lab[k]) * Double(lab[k])
                }
                wsum += w
            }
            if wsum <= 0 { return nil }
            var mean = SIMD3<Float>(), std = SIMD3<Float>()
            for k in 0..<3 {
                mean[k] = Float(sum[k] / wsum)
                let m = sum[k] / wsum
                std[k] = Float(Swift.max(sq[k] / wsum - m * m, 0).squareRoot())
            }
            return LabStats(mean: mean, std: std)
        }

        /// Image › Adjustments › Match Color options (Photoshop ranges).
        struct MatchColor {
            /// 1...200 (100 = matched luminance).
            var luminance: Float = 100
            /// Color intensity 1...200 (100 = matched chroma; 1 ≈ gray).
            var intensity: Float = 100
            /// 0...100: blend back toward the original.
            var fade: Float = 0
            /// Remove the colour cast (target a/b means → 0).
            var neutralize = false
        }

        /// Reinhard-style colour transfer in Lab: shift and scale each channel of `px` (statistics
        /// `target`) toward `source`'s statistics; with no source only Neutralize / intensity /
        /// luminance act on the image's own statistics.
        static func matchColor(_ px: inout [SIMD4<Float>], _ target: LabStats, _ source: LabStats?, _ o: MatchColor) {
            let src = source ?? target
            let lum = o.luminance / 100
            let inten = o.intensity / 100
            let fade = clamp(o.fade / 100, 0, 1)
            func scale(_ k: Int) -> Float { target.std[k] > 1e-4 ? src.std[k] / target.std[k] : 1 }
            var dst = src.mean
            if o.neutralize {
                dst[1] = 0
                dst[2] = 0
            }
            for i in px.indices where px[i].w > 0 {
                let c = SIMD3(px[i].x, px[i].y, px[i].z)
                let lab = ColorConvert.srgbToLab(c)
                let l = ((lab.x - target.mean.x) * scale(0) + dst.x) * lum
                let a = ((lab.y - target.mean.y) * scale(1) + dst.y) * inten
                let b = ((lab.z - target.mean.z) * scale(2) + dst.z) * inten
                let out = ColorConvert.labToSRGB(SIMD3(clamp(l, 0, 100), a, b))
                px[i].x = clamp(out.x + (c.x - out.x) * fade, 0, 1)
                px[i].y = clamp(out.y + (c.y - out.y) * fade, 0, 1)
                px[i].z = clamp(out.z + (c.z - out.z) * fade, 0, 1)
            }
        }

        // MARK: HDR Toning

        /// Image › Adjustments › HDR Toning ("Local Adaptation" method) parameters.
        struct HdrToning {
            /// Edge glow radius in px (1...500).
            var radius: Float = 30
            /// Edge glow strength 0.1...4.
            var strength: Float = 0.5
            /// 0.1...2 (1 = neutral; lower = more contrast).
            var gamma: Float = 1
            /// -5...5 stops.
            var exposure: Float = 0
            /// -100...300 %.
            var detail: Float = 30
            var shadow: Float = 0
            var highlight: Float = 0
            /// -100...100.
            var vibrance: Float = 0
            var saturation: Float = 20
            /// Toning curve on luminance, (input, output) in 0...1; empty = identity.
            var curve: [(Float, Float)] = []
        }

        static func curveEval(_ pts: [(Float, Float)], _ x: Float) -> Float {
            if pts.count < 2 { return x }
            if x <= pts[0].0 { return pts[0].1 }
            for i in 0..<(pts.count - 1) {
                let (a, b) = (pts[i], pts[i + 1])
                if x <= b.0 {
                    let span = Swift.max(b.0 - a.0, 1e-6)
                    return a.1 + (b.1 - a.1) * (x - a.0) / span
                }
            }
            return pts[pts.count - 1].1
        }

        /// Local adaptation tone mapping (Durand–Dorsey style base/detail split in log luminance):
        /// the blurred log luminance (radius) is the base layer, compressed toward its mean by
        /// `strength`; detail is boosted; then exposure, gamma, shadow/highlight lift, the toning
        /// curve, and vibrance/saturation. Like Photoshop the result is a flattened, low-dynamic-range
        /// image.
        static func hdrToning(_ px: inout [SIMD4<Float>], _ w: Int, _ h: Int, _ p: HdrToning) {
            if px.isEmpty { return }
            let eps: Float = 1e-4
            let logl = px.map { logf(Swift.max(luma(SIMD3($0.x, $0.y, $0.z)), 0) + eps) }
            var base = logl
            gaussBlurN(&base, w, h, 1, Swift.max(p.radius, 1) / 2)
            let n = Float(Swift.max(px.reduce(0) { $0 + ($1.w > 0 ? 1 : 0) }, 1))
            var total: Float = 0
            for i in px.indices where px[i].w > 0 { total += base[i] }
            let mean = total / n
            let compress = 1 / (1 + Swift.max(p.strength, 0))
            let detail = 1 + p.detail / 100
            let exposure = powf(2, p.exposure)
            let gamma = clamp(p.gamma, 0.1, 4)
            let sorted = p.curve.enumerated().sorted { a, b in a.element.0 != b.element.0 ? a.element.0 < b.element.0 : a.offset < b.offset }.map(\.element)
            for i in px.indices {
                let q = px[i]
                if q.w <= 0 { continue }
                let c = SIMD3(q.x, q.y, q.z)
                let l0 = Swift.max(luma(c), 0) + eps
                let newLog = mean + (base[i] - mean) * compress + (logl[i] - base[i]) * detail
                // The contract is "lower = more contrast", i.e. gamma is the divisor of the exponent.
                var l1 = powf(Swift.max(expf(newLog) * exposure, 0), 1 / gamma)
                let inv = 1 - l1
                l1 += p.shadow / 100 * (inv * inv * inv) * 0.5 - p.highlight / 100 * (l1 * l1 * l1) * 0.5
                l1 = curveEval(sorted, clamp(l1, 0, 1))
                let ratio = l1 / l0
                var out = c * ratio
                // Saturation then vibrance (less saturated colours move more), around the new luminance.
                let ll = luma(out)
                let mx = Swift.max(Swift.max(out.x, out.y), out.z), mn = Swift.min(Swift.min(out.x, out.y), out.z)
                let satNow: Float = mx > 0 ? (mx - mn) / mx : 0
                let s = 1 + p.saturation / 100 + p.vibrance / 100 * (1 - satNow)
                out = SIMD3(repeating: ll) + (out - SIMD3(repeating: ll)) * Swift.max(s, 0)
                px[i] = SIMD4(clamp(out.x, 0, 1), clamp(out.y, 0, 1), clamp(out.z, 0, 1), q.w)
            }
        }

        // MARK: Blur

        /// Odd box widths whose 3-fold convolution approximates a Gaussian of `sigma` (Kovesi 2010),
        /// returned as radii.
        static func gaussBoxRadii(_ sigma: Float) -> [Int] {
            let n: Float = 3
            let wIdeal = (12 * sigma * sigma / n + 1).squareRoot()
            let fl = wIdeal.rounded(.down)
            var wl = fl.isFinite ? Int32(Swift.max(Swift.min(fl, Float(Int32.max)), Float(Int32.min))) : 0
            if wl % 2 == 0 { wl -= 1 }
            wl = Swift.max(wl, 1)
            let wu = wl + 2
            let mf = clamp(((12 * sigma * sigma - n * Float(wl &* wl) - 4 * n * Float(wl) - 3 * n) / (-4 * Float(wl) - 4)).rounded(), 0, n)
            let m = mf.isFinite ? Int(mf) : 0
            var radii = (0..<3).map { $0 < m ? Int(wl - 1) / 2 : Int(wu - 1) / 2 }
            // Kovesi's rounded triple degenerates below sigma ~ 0.577: one radius-1 pass is the
            // smallest real blur (photocraft #706).
            if radii.allSatisfy({ $0 == 0 }) { radii[0] = 1 }
            return radii
        }

        /// Approximate Gaussian blur (three box passes) of an interleaved buffer.
        static func gaussBlurN(_ buf: inout [Float], _ w: Int, _ h: Int, _ n: Int, _ sigma: Float) {
            if sigma < 0.3 { return }
            let radii = gaussBoxRadii(sigma)
            for r in radii { boxRowsN(&buf, w, n, r) }
            for r in radii { boxColsN(&buf, w, h, n, r) }
        }

        static func boxRowsN(_ buf: inout [Float], _ w: Int, _ n: Int, _ r: Int) {
            if r == 0 || w == 0 || n == 0 { return }
            let norm = 1 / Double(2 * r + 1)
            let stride = w * n
            var row0 = 0
            while row0 + stride <= buf.count {
                let scratch = Array(buf[row0..<(row0 + stride)])
                func at(_ x: Int, _ c: Int) -> Double { Double(scratch[Swift.min(Swift.max(x, 0), w - 1) * n + c]) }
                for c in 0..<n {
                    var acc = 0.0
                    for x in -r...r { acc += at(x, c) }
                    for x in 0..<w {
                        buf[row0 + x * n + c] = Float(acc * norm)
                        acc += at(x + r + 1, c) - at(x - r, c)
                    }
                }
                row0 += stride
            }
        }

        static func boxColsN(_ buf: inout [Float], _ w: Int, _ h: Int, _ n: Int, _ r: Int) {
            if r == 0 || h == 0 || w == 0 || n == 0 || buf.count < w * h * n { return }
            let norm = 1 / Double(2 * r + 1)
            var scratch = [Float](repeating: 0, count: h * n)
            for x in 0..<w {
                for y in 0..<h { for c in 0..<n { scratch[y * n + c] = buf[(y * w + x) * n + c] } }
                func at(_ y: Int, _ c: Int) -> Double { Double(scratch[Swift.min(Swift.max(y, 0), h - 1) * n + c]) }
                for c in 0..<n {
                    var acc = 0.0
                    for y in -r...r { acc += at(y, c) }
                    for y in 0..<h {
                        buf[(y * w + x) * n + c] = Float(acc * norm)
                        acc += at(y + r + 1, c) - at(y - r, c)
                    }
                }
            }
        }
    }
}
