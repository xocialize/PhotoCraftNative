// Port of photocraft-algo (crates/algo/src/selection.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Selection algorithms on coverage masks (`w × h` row-major Float in 0…1 over an area): magic
// wand, Color Range (single colour, several samples, the Lab box, hue families, tonal ranges),
// the anti-aliased lasso polygon, and the modifiers (expand, contract, border, smooth, feather;
// in SelectionDistance.swift / SelectionBlur.swift). Functions with a Metal path take a
// `Backend`: `.cpu` is the reference, `.gpu` the kernels in Shaders/Selection*.metal (which
// match it bit for bit except where documented). `.auto` runs the CPU: these APIs take and
// return host arrays, and at 4096² the transfers cost more than the kernels save (release,
// M5 Max: color range 4.2 ms CPU vs 26.9 ms GPU, contiguous wand 11 vs 65, expand 53 vs 75,
// feather σ 25 15 vs 21). The Metal paths pay off once masks stay GPU-resident.
// Pixels are straight RGBA in 0…1 (`[SIMD4<Float>]`, photocraft's `[[f32; 4]]`).

import Foundation
import PCFoundation

/// Selection algorithms (photocraft `selection`).
public enum Selection {
    /// Whether to run on the GPU: only for `.gpu` (throws without Metal); `.auto` is the CPU (see
    /// the file header for the measurements).
    static func useGPU(_ backend: Backend, _ n: Int) throws -> Bool {
        switch backend {
        case .cpu, .auto: return false
        case .gpu:
            guard AlgoGPU.isAvailable else { throw FilterError.gpuUnavailable("no Metal device or PCAlgo library") }
            return true
        }
    }

    // MARK: Magic wand

    /// photocraft `close`: per-channel difference ≤ `tol` levels (alpha included), or both fully
    /// transparent.
    @inline(__always)
    static func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ tol: Float) -> Bool {
        if a.w == 0 && b.w == 0 { return true }
        let t = tol + 1e-3
        return abs(a.x - b.x) * 255 <= t && abs(a.y - b.y) * 255 <= t && abs(a.z - b.z) * 255 <= t && abs(a.w - b.w) * 255 <= t
    }

    /// Magic Wand: pixels similar to the seed pixel (per-channel difference ≤ `tolerance` levels,
    /// alpha included; fully transparent pixels match each other whatever their hidden RGB).
    /// `contiguous` limits it to the 4-connected region around the seed; `antiAlias` softens the
    /// edge (3×3 average). `px` covers `area`; a seed outside it selects nothing.
    public static func magicWand(_ px: [SIMD4<Float>], area: PixelRect, seed: (x: Int32, y: Int32), tolerance: Float,
                                 contiguous: Bool, antiAlias: Bool, on backend: Backend = .auto) throws -> [Float] {
        let w = area.width, h = area.height
        precondition(px.count >= w * h, "magicWand: \(px.count) pixels for \(area)")
        if !area.contains(x: seed.x, y: seed.y) { return [Float](repeating: 0, count: w * h) }
        let si = Int(seed.y - area.y0) * w + Int(seed.x - area.x0)
        if try useGPU(backend, w * h) {
            return try SelectionKit.GPU.magicWand(px, w: w, h: h, seed: si, tolerance: tolerance, contiguous: contiguous, antiAlias: antiAlias)
        }
        return magicWandCPU(px, w: w, h: h, seed: si, tolerance: tolerance, contiguous: contiguous, antiAlias: antiAlias)
    }

    static func magicWandCPU(_ px: [SIMD4<Float>], w: Int, h: Int, seed si: Int, tolerance: Float, contiguous: Bool, antiAlias: Bool) -> [Float] {
        var m = [Float](repeating: 0, count: w * h)
        let target = px[si]
        if contiguous {
            m.withUnsafeMutableBufferPointer { mb in
                px.withUnsafeBufferPointer { p in
                    var stack = [si]
                    mb[si] = 1
                    @inline(__always) func visit(_ j: Int) {
                        if mb[j] == 0 && close(p[j], target, tolerance) { mb[j] = 1; stack.append(j) }
                    }
                    while let i = stack.popLast() {
                        let x = i % w, y = i / w
                        if x > 0 { visit(i - 1) }
                        if x + 1 < w { visit(i + 1) }
                        if y > 0 { visit(i - w) }
                        if y + 1 < h { visit(i + w) }
                    }
                }
            }
        } else {
            m.withUnsafeMutableBufferPointer { mb in
                let d = UnsafeSendable(mb)
                px.withUnsafeBufferPointer { p in
                    parallelChunks(w * h, minChunk: 1 << 14) { r in
                        for i in r where close(p[i], target, tolerance) { d.value[i] = 1 }
                    }
                }
            }
        }
        if antiAlias { antialias(&m, w, h) }
        return m
    }

    /// Softens hard mask edges: edge pixels become the 3×3 average, kept mostly selected when
    /// selected (photocraft `antialias`; neighbours outside the mask count as the pixel itself).
    static func antialias(_ m: inout [Float], _ w: Int, _ h: Int) {
        let src = m
        m.withUnsafeMutableBufferPointer { mb in
            let d = UnsafeSendable(mb)
            src.withUnsafeBufferPointer { s in
                parallelChunks(h, minChunk: 8) { rows in
                    for y in rows {
                        for x in 0..<w {
                            let i = y * w + x
                            var sum: Float = 0, cnt: Float = 0
                            var edge = false
                            for dy in -1...1 {
                                for dx in -1...1 {
                                    let xx = x + dx, yy = y + dy
                                    let v = xx < 0 || yy < 0 || xx >= w || yy >= h ? s[i] : s[yy * w + xx]
                                    edge = edge || v != s[i]
                                    sum += v
                                    cnt += 1
                                }
                            }
                            if edge { d.value[i] = s[i] > 0.5 ? 0.5 + 0.5 * sum / cnt : 0.5 * sum / cnt }
                        }
                    }
                }
            }
        }
    }

    // MARK: Color Range

    /// Rust `fold(0.0, f32::max)` over the three colour distances in levels.
    @inline(__always)
    static func levelDistance(_ p: SIMD4<Float>, _ c: SIMD3<Float>) -> Float {
        var d: Float = 0
        d = Float.maximum(d, abs(p.x - c.x) * 255)
        d = Float.maximum(d, abs(p.y - c.y) * 255)
        d = Float.maximum(d, abs(p.z - c.z) * 255)
        return d
    }

    /// Color Range: coverage falls off linearly with the largest per-channel distance from
    /// `color`; `fuzziness` in levels (0–200). Transparent pixels are never selected.
    public static func colorRange(_ px: [SIMD4<Float>], color: SIMD3<Float>, fuzziness: Float, on backend: Backend = .auto) throws -> [Float] {
        let f = Float.maximum(fuzziness, 0) + 1
        if try useGPU(backend, px.count) {
            return try SelectionKit.GPU.colorRange(px, samples: [RangeSample(color: color)], w: max(px.count, 1), f: f, localized: nil)
        }
        return SelectionKit.mapPixels(px) { _, p in
            if p.w <= 0 { return 0 }
            return clampf(1 - levelDistance(p, color) / f, 0, 1)
        }
    }

    /// Color Range › Sampled Colors with several samples: each pixel takes its best match over
    /// the samples, each judged like `colorRange`. With `localized` (a radius in pixels) a sample
    /// that has a position also fades with the distance from it, reaching 0 at the radius. `w` is
    /// the row width of `px`.
    public static func colorRangeSamples(_ px: [SIMD4<Float>], w: Int, samples: [RangeSample], fuzziness: Float, localized: Float?,
                                         on backend: Backend = .auto) throws -> [Float] {
        let f = Float.maximum(fuzziness, 0) + 1
        if try useGPU(backend, px.count) {
            return try SelectionKit.GPU.colorRange(px, samples: samples, w: max(w, 1), f: f, localized: localized)
        }
        let ww = max(w, 1)
        return SelectionKit.mapPixels(px) { i, p in
            if p.w <= 0 { return 0 }
            let x = Float(i % ww), y = Float(i / ww)
            var best: Float = 0
            for s in samples {
                var k = clampf(1 - levelDistance(p, s.color) / f, 0, 1)
                if let radius = localized, let at = s.at {
                    let dx = x - at.x, dy = y - at.y
                    let dist = (dx * dx + dy * dy).squareRoot()
                    k *= clampf(1 - dist / Float.maximum(radius, 1), 0, 1)
                }
                best = Float.maximum(best, k)
            }
            return best
        }
    }

    /// How much a Lab colour belongs to `range` at `fuzziness` (0–200), the way Photoshop's
    /// Select › Color Range › Sampled Colors decides it (photocraft `lab_range_coverage`; see its
    /// docs for the measurements): per-axis distance outside the box (L × 2.55; a, b × 3), the
    /// largest one through a quadratic B-spline of width fuzziness × 256/255, quantised to 256
    /// levels.
    public static func labRangeCoverage(_ lab: SIMD3<Float>, _ range: LabRange, fuzziness: Float) -> Float {
        SelectionKit.labCoverage(lab, range, fuzziness, false)
    }

    /// `labRangeCoverage` for 8-bit documents (uneven a/b steps on Photoshop's 8-bit Lab grid).
    public static func labRangeCoverage8bit(_ lab: SIMD3<Float>, _ range: LabRange, fuzziness: Float) -> Float {
        SelectionKit.labCoverage(lab, range, fuzziness, true)
    }

    /// A Lab colour on Photoshop's 8-bit Lab grid (L in 1/2.55 steps, a and b whole units).
    public static func quantizeLab8(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((lab.x * 2.55).rounded() / 2.55, lab.y.rounded(), lab.z.rounded())
    }

    /// Color Range › Sampled Colors over Lab pixels (`lab[i]` = L, a, b, alpha; `w` the row
    /// width): each pixel's Lab coverage (8-bit grid with `grid8`), 0 where transparent. With
    /// `localized` (a radius and the sample positions) coverage fades with the distance to the
    /// nearest sample, reaching 0 at the radius.
    public static func colorRangeLab(_ lab: [SIMD4<Float>], w: Int, range: LabRange, fuzziness: Float, grid8: Bool,
                                     localized: (radius: Float, at: [SIMD2<Float>])?, on backend: Backend = .auto) throws -> [Float] {
        let ww = max(w, 1)
        let loc = localized.flatMap { $0.at.isEmpty ? nil : $0 }
        if try useGPU(backend, lab.count) {
            return try SelectionKit.GPU.colorRangeLab(lab, w: ww, range: range, fuzziness: fuzziness, grid8: grid8, localized: loc)
        }
        return SelectionKit.mapPixels(lab) { i, p in
            if p.w.isNaN || p.w <= 0 { return 0 }
            var k = SelectionKit.labCoverage(SIMD3(p.x, p.y, p.z), range, fuzziness, grid8)
            if let (radius, at) = loc, k > 0 {
                let px = Float(i % ww), py = Float(i / ww)
                var near: Float = 0
                for s in at {
                    let dx = px - s.x, dy = py - s.y
                    near = Float.maximum(near, clampf(1 - (dx * dx + dy * dy).squareRoot() / Float.maximum(radius, 1), 0, 1))
                }
                k *= near
            }
            return k
        }
    }

    /// Color Range › Select: Reds, Yellows, Greens, Cyans, Blues or Magentas (`center` = 0, 60,
    /// 120, 180, 240, 300°): closeness of the hue (full at the family's hue, none 60° away) times
    /// the chroma, so neutrals are never selected and muted colours only partly.
    public static func hueRange(_ px: [SIMD4<Float>], center: Float, on backend: Backend = .auto) throws -> [Float] {
        if try useGPU(backend, px.count) { return try SelectionKit.GPU.hueRange(px, center: center) }
        return SelectionKit.mapPixels(px) { _, p in
            if p.w <= 0 { return 0 }
            let (hue, chroma) = SelectionKit.hueChroma(SIMD3(clampf(p.x, 0, 1), clampf(p.y, 0, 1), clampf(p.z, 0, 1)))
            var dh = euclidMod(hue - center, 360)
            dh = Float.minimum(dh, 360 - dh)
            return clampf(clampf(1 - dh / 60, 0, 1) * chroma, 0, 1)
        }
    }

    /// Color Range › Select: Highlights, Midtones or Shadows: luminance (Rec. 601, 0…255) in
    /// `lo…hi` is fully selected, falling off linearly to 0 over `falloff` levels outside.
    public static func toneRange(_ px: [SIMD4<Float>], lo: Float, hi: Float, falloff: Float, on backend: Backend = .auto) throws -> [Float] {
        if try useGPU(backend, px.count) { return try SelectionKit.GPU.toneRange(px, lo: lo, hi: hi, falloff: falloff) }
        let ramp = Float.maximum(falloff, 1e-3)
        return SelectionKit.mapPixels(px) { _, p in
            if p.w <= 0 { return 0 }
            let l = clampf(0.299 * p.x + 0.587 * p.y + 0.114 * p.z, 0, 1) * 255
            let out: Float = l < lo ? lo - l : (l > hi ? l - hi : 0)
            return clampf(1 - out / ramp, 0, 1)
        }
    }

    // MARK: Lasso

    /// Anti-aliased polygon (even-odd) coverage over `area`: exact horizontal coverage on 4
    /// sub-rows per pixel row (1 without anti-aliasing, where a pixel is in when its centre is).
    /// CPU only: per-scanline crossing lists don't map onto per-pixel threads, and it is cheap.
    public static func polygon(_ points: [SIMD2<Float>], area: PixelRect, antiAlias: Bool) -> [Float] {
        let w = area.width, h = area.height
        var m = [Float](repeating: 0, count: w * h)
        if points.count < 3 { return m }
        let sub = antiAlias ? 4 : 1
        let fsub = Float(sub)
        let ax0 = Float(area.x0)
        m.withUnsafeMutableBufferPointer { mb in
            let d = UnsafeSendable(mb)
            parallelChunks(h, minChunk: 4) { rows in
                var xs: [Float] = []
                for py in rows {
                    for s in 0..<sub {
                        let y = Float(area.y0) + Float(py) + (Float(s) + 0.5) / fsub
                        xs.removeAll(keepingCapacity: true)
                        for i in 0..<points.count {
                            let a = points[i], b = points[(i + 1) % points.count]
                            if (a.y <= y && b.y > y) || (b.y <= y && a.y > y) {
                                xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
                            }
                        }
                        xs.sort { SelectionKit.totalLess($0, $1) }
                        var k = 0
                        while k + 1 < xs.count {
                            let x0 = Float.maximum(xs[k] - ax0, 0), x1 = Float.minimum(xs[k + 1] - ax0, Float(w))
                            k += 2
                            if !(x1 > x0) { continue }
                            let c0 = Int(x0.rounded(.down)), c1 = min(SelectionKit.usizeCast(x1.rounded(.up)), w)
                            if c0 >= c1 { continue }
                            for cx in c0..<c1 {
                                let cov: Float
                                if antiAlias {
                                    cov = Float.minimum(Float(cx + 1), x1) - Float.maximum(Float(cx), x0)
                                } else {
                                    let c = Float(cx) + 0.5
                                    cov = c >= x0 && c < x1 ? 1 : 0
                                }
                                d.value[py * w + cx] += Float.maximum(cov, 0) / fsub
                            }
                        }
                    }
                }
            }
            for i in 0..<mb.count { mb[i] = Float.minimum(mb[i], 1) }
        }
        return m
    }
}

/// Shared helpers of the selection port.
enum SelectionKit {
    /// `f(i, px[i])` for every pixel, in parallel.
    static func mapPixels(_ px: [SIMD4<Float>], _ f: (Int, SIMD4<Float>) -> Float) -> [Float] {
        var out = [Float](repeating: 0, count: px.count)
        out.withUnsafeMutableBufferPointer { ob in
            let o = UnsafeSendable(ob)
            px.withUnsafeBufferPointer { p in
                parallelChunks(p.count, minChunk: 1 << 13) { r in
                    for i in r { o.value[i] = f(i, p[i]) }
                }
            }
        }
        return out
    }

    /// Rust's `f32::total_cmp` as a strict ordering.
    @inline(__always)
    static func totalLess(_ a: Float, _ b: Float) -> Bool {
        a.isTotallyOrdered(belowOrEqualTo: b) && !b.isTotallyOrdered(belowOrEqualTo: a)
    }

    /// Rust's saturating `f32 as usize` (NaN and negatives → 0).
    @inline(__always)
    static func usizeCast(_ v: Float) -> Int {
        if !(v > 0) { return 0 }
        return v >= 9.2e18 ? Int.max : Int(v)
    }

    /// Rust's saturating `f32 as i32` (NaN → 0).
    @inline(__always)
    static func i32Cast(_ v: Float) -> Int32 {
        if v.isNaN { return 0 }
        return Int32(min(max(v, -2147483648), 2147483520))
    }

    /// Rust's saturating `f32 as u8`.
    @inline(__always)
    static func u8Cast(_ v: Float) -> UInt8 {
        if !(v > 0) { return 0 }
        return v >= 255 ? 255 : UInt8(v)
    }

    /// The 8-bit selection value of a coverage (clamped and rounded as GRAY8 stores it; NaN → 0) —
    /// photocraft `coverage8` / `write_sample(U8)`.
    @inline(__always)
    static func coverage8(_ v: Float) -> UInt8 { u8Cast(clampf(v, 0, 1) * 255 + 0.5) }

    /// Hue (degrees, 0…360) and chroma (max − min) of an RGB colour (photocraft `hue_chroma`).
    @inline(__always)
    static func hueChroma(_ c: SIMD3<Float>) -> (Float, Float) {
        let (r, g, b) = (c.x, c.y, c.z)
        let mx = Float.maximum(Float.maximum(r, g), b), mn = Float.minimum(Float.minimum(r, g), b)
        let d = mx - mn
        if d <= 0 { return (0, 0) }
        let hue: Float
        if mx == r { hue = euclidMod((g - b) / d, 6) } else if mx == g { hue = (b - r) / d + 2 } else { hue = (r - g) / d + 4 }
        return (hue * 60, d)
    }

    /// photocraft `selection::coverage` (Lab box membership).
    static func labCoverage(_ lab: SIMD3<Float>, _ range: LabRange, _ fuzziness: Float, _ grid8: Bool) -> Float {
        @inline(__always) func outside(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
            Float.maximum(Float.maximum(lo - v, v - hi), 0)
        }
        if fuzziness.isNaN || fuzziness <= 0 {
            let d = Float.maximum(Float.maximum(outside(lab.x, range.lo.x, range.hi.x) * 2.55, outside(lab.y, range.lo.y, range.hi.y)),
                                  outside(lab.z, range.lo.z, range.hi.z))
            return d < 0.5 ? 1 : 0
        }
        @inline(__always) func ab(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
            if !grid8 { return outside(v, lo, hi) }
            if v > hi { return v - hi + 0.5 }
            if v < lo { return Float.maximum(lo - v - 0.5, 0) }
            return 0
        }
        let dl = outside(lab.x, range.lo.x, range.hi.x) * 2.55
        let da = 3 * ab(lab.y, range.lo.y, range.hi.y)
        let db = 3 * ab(lab.z, range.lo.z, range.hi.z)
        let t = Float.maximum(Float.maximum(dl, da), db) / (fuzziness * 256 / 255)
        let v: Float = t <= 0.5 ? 1 - 2 * t * t : (t < 1 ? 2 * (1 - t) * (1 - t) : 0)
        return clampf((v * 256).rounded(.down), 0, 255) / 255
    }
}
