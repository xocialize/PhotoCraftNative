// Port of photocraft-algo (crates/algo/src/hdr.rs; photo_util.rs: solve_dense, Normal), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// File › Automate › Merge to HDR Pro: exposure estimation, alignment, camera response recovery,
// radiance merge, ghost removal and the 16/8-bit tone mapping methods.
// - Alignment: G. Ward, "Fast, Robust Image Registration for Compositing High Dynamic Range
//   Photographs from Hand-Held Exposures", JGT 2003 — median threshold bitmaps over a pyramid.
// - Response curve: P. Debevec, J. Malik, "Recovering High Dynamic Range Radiance Maps from
//   Photographs", SIGGRAPH 1997 — weighted least squares with smoothness and g(128) = 0.
// - Merge: the hat-weighted average of g(Z) − ln Δt; ghosts (high weighted variance of the
//   per-exposure log radiance) come from one base exposure, feathered.
// - Tone mapping: Local Adaptation (HDR Toning), Exposure and Gamma, Highlight Compression
//   (Reinhard et al. 2002, global) and Equalize Histogram (of log luminance).
// Pixels are straight RGBA in 0…1 (display-encoded inputs); radiance is linear.
//
// GPU: the per-pixel radiance merge and ghost mask run as Metal kernels (f32 where photocraft
// accumulates in f64 — relative differences ~1e-6); the per-channel scale (a median of a 1/37
// subsample), the stops estimate, the response recovery (a 416-unknown dense solve) and MTB
// alignment stay on the CPU. Tone mapping runs on the GPU as the `HDRToneMap` filter.

import Foundation
import Metal
import PCFoundation

/// Merge options (photocraft `hdr::MergeOptions`).
public struct HDRMergeOptions: Sendable, Hashable, Codable {
    /// Linear exposure factors (time × gain), one per image.
    public var exposures: [Double]
    public var removeGhosts: Bool
    /// Exposure used where ghosts are removed (nil: the one with most well-exposed pixels).
    public var ghostBase: Int?
    /// Response curves per channel, 256 entries each (nil: recovered from the images).
    public var response: [[Double]]?

    public init(exposures: [Double], removeGhosts: Bool = false, ghostBase: Int? = nil, response: [[Double]]? = nil) {
        self.exposures = exposures; self.removeGhosts = removeGhosts; self.ghostBase = ghostBase; self.response = response
    }
}

/// Result of a merge (photocraft `hdr::Merged`).
public struct HDRMerged: Sendable {
    /// Linear radiance, straight RGBA.
    public var px: [SIMD4<Float>]
    public var response: [[Double]]
    public var ghostBase: Int
    /// Fraction of pixels handled as ghosts.
    public var ghostFraction: Double
    /// Dynamic range of the result in stops (1st…99.9th percentile of luminance).
    public var stops: Double
}

/// The four 16/8-bit conversion methods of Merge to HDR Pro / HDR Toning (photocraft
/// `hdr::ToneMethod`).
public enum HDRToneMethod: Sendable, Hashable, Codable {
    case localAdaptation(HdrToning)
    case exposureGamma(exposure: Float, gamma: Float)
    case highlightCompression
    case equalizeHistogram
}

extension ToneKit {
    /// Rec. 709 luminance (photocraft `hdr::luma`).
    @inline(__always)
    static func luma709(_ c: SIMD4<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// Hat weight on a 0…255 code value.
    @inline(__always)
    static func hat(_ z: Double) -> Double { max(z <= 127.5 ? z : 255 - z, 0) }

    /// Rust's saturating `f32 as usize`.
    @inline(__always)
    static func asIndex(_ v: Float) -> Int {
        if v.isNaN || v <= 0 { return 0 }
        if v >= Float(Int.max) { return Int.max }
        return Int(v)
    }

    /// Stable sort of indices by a key in IEEE total order (Rust `sort_by(total_cmp)`).
    static func sortedIndices<T: BinaryFloatingPoint>(_ n: Int, _ key: (Int) -> T) -> [Int] {
        (0..<n).sorted { a, b in
            let ka = key(a), kb = key(b)
            if ka.isTotallyOrdered(belowOrEqualTo: kb) && kb.isTotallyOrdered(belowOrEqualTo: ka) { return a < b }
            return ka.isTotallyOrdered(belowOrEqualTo: kb)
        }
    }

    /// `v` sorted in IEEE total order (Rust `sort_by(total_cmp)`), via order-preserving integer
    /// keys (sign-magnitude → two's-complement-like), which sorts fast and handles −0 and NaN.
    static func totalSorted(_ v: [Float]) -> [Float] {
        var keys = v.map { f -> UInt32 in let b = f.bitPattern; return b & 0x8000_0000 != 0 ? ~b : b | 0x8000_0000 }
        keys.sort()
        return keys.map { k in Float(bitPattern: k & 0x8000_0000 != 0 ? k & 0x7FFF_FFFF : ~k) }
    }

    static func totalSorted(_ v: [Double]) -> [Double] {
        var keys = v.map { f -> UInt64 in let b = f.bitPattern; return b & (1 << 63) != 0 ? ~b : b | (1 << 63) }
        keys.sort()
        return keys.map { k in Double(bitPattern: k & (1 << 63) != 0 ? k & ~(1 << 63) : ~k) }
    }

    // MARK: Exposures

    /// Relative exposures (linear factors, the darkest = 1) estimated from the images themselves:
    /// consecutive images (sorted by brightness) are compared on pixels well exposed in both
    /// (photocraft `estimate_exposures`).
    public static func estimateExposures(_ imgs: [[SIMD4<Float>]]) -> [Double] {
        let n = imgs.count
        let mean: [Double] = imgs.map { im in
            var s = 0.0
            for p in im { s += Double(luma709(p)) }
            return s / Double(max(im.count, 1))
        }
        let order = sortedIndices(n) { mean[$0] }
        var ex = [Double](repeating: 1, count: n)
        if n < 2 { return ex }
        for k in 1..<n {
            let (a, b) = (order[k - 1], order[k])
            var ratios: [Double] = []
            let m = min(imgs[a].count, imgs[b].count)
            var i = 0
            while i < m {
                let (la, lb) = (luma709(imgs[a][i]), luma709(imgs[b][i]))
                if la >= 0.08 && la < 0.92 && lb >= 0.08 && lb < 0.92 {
                    ratios.append(Double(ColorConvert.srgbToLinear(lb)) / Double(Float.maximum(ColorConvert.srgbToLinear(la), 1e-6)))
                }
                i += 7
            }
            ratios = totalSorted(ratios)
            let r = ratios.isEmpty ? 2 : Swift.max(ratios[ratios.count / 2], 1)
            ex[b] = ex[a] * r
        }
        return ex
    }

    // MARK: Alignment

    static func shrink(_ w: Int, _ h: Int, _ g: [Float]) -> (Int, Int, [Float]) {
        let (nw, nh) = (max(w / 2, 1), max(h / 2, 1))
        var out = [Float](repeating: 0, count: nw * nh)
        @inline(__always) func p(_ xx: Int, _ yy: Int) -> Float { g[min(yy, h - 1) * w + min(xx, w - 1)] }
        for y in 0..<nh {
            for x in 0..<nw {
                out[y * nw + x] = 0.25 * (p(2 * x, 2 * y) + p(2 * x + 1, 2 * y) + p(2 * x, 2 * y + 1) + p(2 * x + 1, 2 * y + 1))
            }
        }
        return (nw, nh, out)
    }

    static func bitmaps(_ g: [Float]) -> ([Bool], [Bool]) {
        let s = totalSorted(g)
        let med = s[s.count / 2]
        return (g.map { $0 > med }, g.map { abs($0 - med) > 4.0 / 255.0 })
    }

    /// Translation `(dx, dy)` that aligns grey image `img` to `reference` (Ward's MTB), searching
    /// up to `2^levels` px (photocraft `mtb_offset`).
    public static func mtbOffset(w: Int, h: Int, reference: [Float], image img: [Float], levels: Int) -> (Int32, Int32) {
        if levels == 0 || w < 16 || h < 16 { return (0, 0) }
        let (sw, sh, sr) = shrink(w, h, reference)
        let (_, _, si) = shrink(w, h, img)
        let (px, py) = mtbOffset(w: sw, h: sh, reference: sr, image: si, levels: levels - 1)
        let (curX, curY) = (px * 2, py * 2)
        let (tr, er) = bitmaps(reference)
        let (ti, ei) = bitmaps(img)
        var best: (UInt64, Int32, Int32) = (.max, 0, 0)
        for dy in Int32(-1)...1 {
            for dx in Int32(-1)...1 {
                let (ox, oy) = (curX + dx, curY + dy)
                var err: UInt64 = 0
                for y in 0..<Int32(h) {
                    let sy = y - oy
                    if sy < 0 || sy >= Int32(h) { continue }
                    for x in 0..<Int32(w) {
                        let sx = x - ox
                        if sx < 0 || sx >= Int32(w) { continue }
                        let a = Int(y) * w + Int(x), b = Int(sy) * w + Int(sx)
                        if tr[a] != ti[b] && er[a] && ei[b] { err += 1 }
                    }
                }
                if err < best.0 { best = (err, ox, oy) }
            }
        }
        return (best.1, best.2)
    }

    // MARK: Response curve

    /// Sample pixel indices for response recovery: a spatial grid filtered to pixels whose
    /// neighbourhood is flat in the middle exposure, stratified by intensity (photocraft
    /// `sample_pixels`).
    public static func samplePixels(w: Int, h: Int, middle: [SIMD4<Float>], count: Int) -> [Int] {
        var byBin = [[Int]](repeating: [], count: 32)
        let step = max(Int(max((Double(w * h / max(count * 40, 1))).squareRoot(), 1)), 1)
        if h > 4 && w > 4 {
            for y in stride(from: 2, to: h - 2, by: step) {
                for x in stride(from: 2, to: w - 2, by: step) {
                    let i = y * w + x
                    let l = luma709(middle[i])
                    let flat = [i - 2, i + 2, i - 2 * w, i + 2 * w].allSatisfy { abs(luma709(middle[$0]) - l) < 0.04 }
                    if flat { byBin[min(asIndex(l * 31.99), 31)].append(i) }
                }
            }
        }
        var out: [Int] = []
        var k = 0
        while out.count < count && byBin.contains(where: { k < $0.count }) {
            for b in byBin where k < b.count {
                out.append(b[k * 7 % max(b.count, 1)])
                if out.count >= count { break }
            }
            k += 1
        }
        out.sort()
        var dedup: [Int] = []
        for v in out where dedup.last != v { dedup.append(v) }
        return dedup
    }

    /// Debevec–Malik response curve: `z[j][i]` is the code value (0…255) of sample `i` in exposure
    /// `j`; returns g(0…255) (log exposure per code value, g(128) = 0), smoothed by `lambda`
    /// (photocraft `response_curve`).
    public static func responseCurve(_ z: [[UInt8]], logDt: [Double], lambda: Double) -> [Double] {
        let p = z.count
        let n = z.first?.count ?? 0
        var ne = NormalEquations(256 + n)
        for j in 0..<p {
            for i in 0..<n {
                let zz = Int(z[j][i])
                let w = hat(Double(zz)) + 1
                ne.add([(zz, 1), (256 + i, -1)], logDt[j], w)
            }
        }
        ne.add([(128, 1)], 0, 100)
        for k in 1..<255 {
            let w = lambda.squareRoot() * (hat(Double(k)) + 1)
            ne.add([(k - 1, 1), (k, -2), (k + 1, 1)], 0, w)
        }
        guard let x = ne.solve() else {
            // Fall back to the sRGB curve.
            let mid = log(Double(ColorConvert.srgbToLinear(128.0 / 255.0)))
            return (0..<256).map { k in log(Double(Float.maximum(ColorConvert.srgbToLinear(Float(k) / 255), 1e-5))) - mid }
        }
        var g = Array(x[0..<256])
        // Enforce monotonicity (noise at the extremes can fold the curve).
        for k in stride(from: 127, through: 0, by: -1) { g[k] = min(g[k], g[k + 1] - 1e-4) }
        for k in 129..<256 { g[k] = max(g[k], g[k - 1] + 1e-4) }
        return g
    }

    @inline(__always)
    static func gAt(_ g: UnsafeBufferPointer<Double>, _ v: Float) -> Double {
        let x = Double(clampf(v, 0, 1) * 255)
        let i = min(Int(x.rounded(.down)), 254)
        let t = x - Double(i)
        return g[i] * (1 - t) + g[i + 1] * t
    }

    // MARK: Merge

    /// Merges aligned exposures (`w × h` each) into a radiance map, scaled so the base exposure's
    /// well-exposed pixels keep their linear values (photocraft `hdr::merge`). `.gpu` / `.auto`
    /// run the per-pixel merge and ghost mask in Metal.
    public static func mergeHDR(w: Int, h: Int, images imgs: [[SIMD4<Float>]], options opts: HDRMergeOptions,
                                on backend: Backend = .cpu) throws -> HDRMerged {
        let p = imgs.count
        precondition(p > 0 && opts.exposures.count >= p && imgs.allSatisfy { $0.count == w * h }, "mergeHDR: shape")
        let logDt = opts.exposures.map { log(max($0, 1e-12)) }
        func well(_ im: [SIMD4<Float>]) -> Int {
            var c = 0, i = 0
            while i < im.count { let l = luma709(im[i]); if l >= 0.1 && l < 0.9 { c += 1 }; i += 3 }
            return c
        }
        var base = 0
        if let gb = opts.ghostBase, gb < p { base = gb } else {
            var bestW = -1
            for j in 0..<p { let wj = well(imgs[j]); if wj >= bestW { bestW = wj; base = j } }   // max_by_key: last maximum
        }
        let response: [[Double]] = opts.response ?? {
            let order = sortedIndices(p) { opts.exposures[$0] }
            let mid = order[p / 2]
            let samples = samplePixels(w: w, h: h, middle: imgs[mid], count: 160)
            return (0..<3).map { c in
                let z: [[UInt8]] = imgs.map { im in samples.map { UInt8((clampf(im[$0][c], 0, 1) * 255).rounded()) } }
                return responseCurve(z, logDt: logDt, lambda: 40)
            }
        }()
        let useGPU: Bool
        switch backend {
        case .cpu: useGPU = false
        case .gpu: useGPU = true
        case .auto: useGPU = AlgoGPU.isAvailable
        }
        var px: [SIMD4<Float>]
        var ghostFraction = 0.0
        if useGPU {
            (px, ghostFraction) = try mergeGPU(w, h, imgs, logDt, response, base, opts.removeGhosts && p > 1)
        } else {
            (px, ghostFraction) = mergeCPU(w, h, imgs, logDt, response, base, opts.removeGhosts && p > 1)
        }
        // Scale per channel so the base exposure's well-exposed pixels map to their linear values.
        for c in 0..<3 {
            var r: [Double] = []
            var i = 0
            while i < w * h {
                let v = imgs[base][i][c]
                if v >= 0.15 && v < 0.85 && px[i][c] > 0 {
                    r.append(Double(ColorConvert.srgbToLinear(v)) / (Double(px[i][c]) * opts.exposures[base]))
                }
                i += 37
            }
            r = totalSorted(r)
            let k = (r.isEmpty ? 1 : r[r.count / 2]) * opts.exposures[base]
            px.withUnsafeMutableBufferPointer { q in
                let qs = UnsafeSendable(q)
                parallelChunks(q.count, minChunk: 16384) { rr in for i in rr { qs.value[i][c] = Float(Double(qs.value[i][c]) * k) } }
            }
        }
        var l: [Float] = []
        var i = 0
        while i < px.count { if px[i].w > 0 { l.append(Float.maximum(luma709(px[i]), 1e-9)) }; i += 13 }
        l = totalSorted(l)
        let stops = l.isEmpty ? 0 : log2(Double(l[Int(Double(l.count) * 0.999) % l.count]) / Double(l[l.count / 100]))
        return HDRMerged(px: px, response: response, ghostBase: base, ghostFraction: ghostFraction, stops: stops)
    }

    /// The radiance merge and ghost handling on the CPU (before the per-channel scale).
    static func mergeCPU(_ w: Int, _ h: Int, _ imgs: [[SIMD4<Float>]], _ logDt: [Double], _ response: [[Double]],
                         _ base: Int, _ ghosts: Bool) -> ([SIMD4<Float>], Double) {
        let p = imgs.count
        var px = [SIMD4<Float>](repeating: .zero, count: w * h)
        let resp = response.map { Array($0) }
        resp[0].withUnsafeBufferPointer { r0 in resp[1].withUnsafeBufferPointer { r1 in resp[2].withUnsafeBufferPointer { r2 in
            let rs = UnsafeSendable([r0, r1, r2])
            px.withUnsafeMutableBufferPointer { out in
                let os = UnsafeSendable(out)
                parallelChunks(w * h, minChunk: 4096) { range in
                    for i in range {
                        var o = SIMD4<Float>(repeating: 0)
                        for c in 0..<3 {
                            var num = 0.0, den = 0.0
                            for j in 0..<p {
                                let v = imgs[j][i][c]
                                let wt = hat(Double(clampf(v, 0, 1)) * 255)
                                num += wt * (gAt(rs.value[c], v) - logDt[j])
                                den += wt
                            }
                            let le: Double
                            if den > 1e-6 { le = num / den } else {
                                // Saturated everywhere: darkest exposure if bright, brightest if dark.
                                var s: Float = 0
                                for j in 0..<p { s += imgs[j][i][c] }
                                let bright = s / Float(p) > 0.5
                                var jb = 0
                                for j in 1..<max(p, 1) where bright ? logDt[j] < logDt[jb] : logDt[j] > logDt[jb] { jb = j }
                                le = gAt(rs.value[c], imgs[jb][i][c]) - logDt[jb]
                            }
                            o[c] = Float(exp(le))
                        }
                        var alpha: Float = 0
                        for j in 0..<p { alpha = Float.maximum(alpha, imgs[j][i].w) }
                        o.w = alpha
                        os.value[i] = o
                    }
                }
            }
        } } }
        guard ghosts else { return (px, 0) }
        // Weighted variance of per-exposure log radiance (luminance).
        var ghost = [Float](repeating: 0, count: w * h)
        resp[0].withUnsafeBufferPointer { r0 in resp[1].withUnsafeBufferPointer { r1 in resp[2].withUnsafeBufferPointer { r2 in
            let rs = UnsafeSendable([r0, r1, r2])
            ghost.withUnsafeMutableBufferPointer { gb in
                let gs = UnsafeSendable(gb)
                parallelChunks(w * h, minChunk: 4096) { range in
                    for i in range { gs.value[i] = ghostScore(imgs, i, rs.value, logDt) > 0.35 ? 1 : 0 }
                }
            }
        } } }
        // Grow and feather the mask.
        FxUtil.gaussBlurN(&ghost, w, h, 1, Float.maximum(Float(max(w, h)) / 200, 2))
        for i in 0..<ghost.count { ghost[i] = Float.minimum(ghost[i] * 3, 1) }
        let fraction = Double(ghost.filter { $0 > 0.5 }.count) / Double(max(w * h, 1))
        let ld = logDt[base]
        resp[0].withUnsafeBufferPointer { r0 in resp[1].withUnsafeBufferPointer { r1 in resp[2].withUnsafeBufferPointer { r2 in
            let rs = [r0, r1, r2]
            for i in 0..<(w * h) where ghost[i] > 0 {
                let q = imgs[base][i]
                for c in 0..<3 {
                    let e = Float(exp(gAt(rs[c], q[c]) - ld))
                    px[i][c] = px[i][c] * (1 - ghost[i]) + e * ghost[i]
                }
            }
        } } }
        return (px, fraction)
    }

    /// Weighted standard deviation of the per-exposure log radiance of pixel `i`.
    @inline(__always)
    static func ghostScore(_ imgs: [[SIMD4<Float>]], _ i: Int, _ resp: [UnsafeBufferPointer<Double>], _ logDt: [Double]) -> Float {
        var s = 0.0, s2 = 0.0, sw = 0.0
        for j in 0..<imgs.count {
            let q = imgs[j][i]
            let wt = hat(Double(luma709(q)) * 255)
            if wt < 20 { continue }
            var lr = 0.0
            for c in 0..<3 { lr += 0.33 * (gAt(resp[c], q[c]) - logDt[j]) }
            s += wt * lr
            s2 += wt * lr * lr
            sw += wt
        }
        if sw <= 0 { return 0 }
        let m = s / sw
        return Float(max(s2 / sw - m * m, 0).squareRoot())
    }

    // MARK: Tone mapping

    /// Tone maps linear radiance to display-encoded (sRGB curve) values in 0…1 (photocraft
    /// `hdr::tone_map`).
    public static func toneMap(_ px: inout [SIMD4<Float>], w: Int, h: Int, method: HDRToneMethod) {
        var n = 0
        var logSum = 0.0
        for q in px where q.w > 0 { logSum += log(Double(Float.maximum(luma709(q), 1e-6))); n += 1 }
        let logMean = Float(exp(logSum / Double(max(n, 1))))
        switch method {
        case .localAdaptation(let p):
            // Key the scene to middle grey, compress in log luminance, then encode.
            let k = 0.18 / Float.maximum(logMean, 1e-6)
            for i in 0..<px.count { px[i].x *= k; px[i].y *= k; px[i].z *= k }
            hdrToning(&px, w: w, h: h, p)
            mapRGB(&px) { ColorConvert.linearToSRGB(clampf($0, 0, 1)) }
        case .exposureGamma(let exposure, let gamma):
            let k = powf(2, exposure)
            let g = clampf(gamma, 0.1, 10)
            mapRGB(&px) { powf(ColorConvert.linearToSRGB(clampf($0 * k, 0, 1)), 1 / g) }
        case .highlightCompression:
            let k = 0.18 / Float.maximum(logMean, 1e-6)
            px.withUnsafeMutableBufferPointer { q in
                let qs = UnsafeSendable(q)
                parallelChunks(q.count, minChunk: 4096) { r in
                    for i in r { qs.value[i] = highlightCompress(qs.value[i], k) }
                }
            }
        case .equalizeHistogram:
            let bins = 1024
            let lv = px.map { logf(Float.maximum(luma709($0), 1e-7)) }
            var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
            for i in 0..<px.count where px[i].w > 0 { lo = Float.minimum(lo, lv[i]); hi = Float.maximum(hi, lv[i]) }
            let span = Float.maximum(hi - lo, 1e-6)
            var hist = [Double](repeating: 0, count: bins)
            for i in 0..<px.count where px[i].w > 0 { hist[asIndex((lv[i] - lo) / span * Float(bins - 1))] += 1 }
            let cdf = equalizeCDF(hist)
            px.withUnsafeMutableBufferPointer { q in
                let qs = UnsafeSendable(q)
                parallelChunks(q.count, minChunk: 4096) { r in
                    for i in r { qs.value[i] = equalize(qs.value[i], lv[i], lo, span, cdf) }
                }
            }
        }
    }

    static func mapRGB(_ px: inout [SIMD4<Float>], _ f: @Sendable (Float) -> Float) {
        px.withUnsafeMutableBufferPointer { q in
            let qs = UnsafeSendable(q)
            parallelChunks(q.count, minChunk: 4096) { r in
                for i in r { for c in 0..<3 { qs.value[i][c] = f(qs.value[i][c]) } }
            }
        }
    }

    @inline(__always)
    static func highlightCompress(_ q: SIMD4<Float>, _ k: Float) -> SIMD4<Float> {
        let l = luma709(q) * k
        let ld = l / (1 + l)
        let r: Float = l > 1e-9 ? ld / l * k : 0
        var o = q
        for c in 0..<3 { o[c] = ColorConvert.linearToSRGB(clampf(q[c] * r, 0, 1)) }
        return o
    }

    static func equalizeCDF(_ hist: [Double]) -> [Float] {
        let total = max(hist.reduce(0, +), 1)
        var cdf = [Float](repeating: 0, count: hist.count)
        var acc = 0.0
        for b in 0..<hist.count { acc += hist[b]; cdf[b] = Float(acc / total) }
        return cdf
    }

    @inline(__always)
    static func equalize(_ q: SIMD4<Float>, _ v: Float, _ lo: Float, _ span: Float, _ cdf: [Float]) -> SIMD4<Float> {
        let target = cdf[asIndex(clampf((v - lo) / span, 0, 1) * Float(cdf.count - 1))]
        // Display value from the CDF (encoded), keep colour ratios in linear light.
        let tl = ColorConvert.srgbToLinear(target)
        let l = Float.maximum(luma709(q), 1e-7)
        var o = q
        for c in 0..<3 { o[c] = ColorConvert.linearToSRGB(clampf(q[c] / l * tl, 0, 1)) }
        return o
    }

    /// `toneMap` on the CPU (`.cpu`) or through the Metal path (`HDRToneMap`).
    public static func toneMap(_ px: inout [SIMD4<Float>], w: Int, h: Int, method: HDRToneMethod, on backend: Backend) throws {
        if backend == .cpu { toneMap(&px, w: w, h: h, method: method) } else { try runRGBA(HDRToneMap(method: method), &px, w: w, h: h, on: backend) }
    }
}

// MARK: - Dense least squares (photocraft photo_util `Normal`, `solve_dense`)

/// Accumulates weighted rows into normal equations AᵀA x = Aᵀb.
struct NormalEquations {
    let n: Int
    var ata: [Double]
    var atb: [Double]

    init(_ n: Int) { self.n = n; ata = [Double](repeating: 0, count: n * n); atb = [Double](repeating: 0, count: n) }

    /// Adds the sparse row Σ coef·x[idx] = rhs with weight `w` (applied squared).
    mutating func add(_ row: [(Int, Double)], _ rhs: Double, _ w: Double) {
        let w2 = w * w
        for (i, a) in row {
            atb[i] += w2 * a * rhs
            for (j, b) in row { ata[i * n + j] += w2 * a * b }
        }
    }

    func solve() -> [Double]? { NormalEquations.solveDense(n, ata, atb) }

    /// Gaussian elimination with partial pivoting; nil when singular.
    static func solveDense(_ n: Int, _ a0: [Double], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        var x = [Double](repeating: 0, count: n)
        let ok: Bool = a.withUnsafeMutableBufferPointer { ab in
            b.withUnsafeMutableBufferPointer { bb in
                x.withUnsafeMutableBufferPointer { xb in
                    guard n > 0, let a = ab.baseAddress, let b = bb.baseAddress, let x = xb.baseAddress else { return true }
                    for col in 0..<n {
                        // Rust `max_by(total_cmp)`: the last of equal maxima.
                        var piv = col
                        var best = abs(a[col * n + col])
                        var i = col + 1
                        while i < n {
                            let v = abs(a[i * n + col])
                            if best.isTotallyOrdered(belowOrEqualTo: v) { piv = i; best = v }
                            i += 1
                        }
                        if abs(a[piv * n + col]) < 1e-14 { return false }
                        if piv != col {
                            for k in 0..<n { let t = a[col * n + k]; a[col * n + k] = a[piv * n + k]; a[piv * n + k] = t }
                            let t = b[col]; b[col] = b[piv]; b[piv] = t
                        }
                        let d = a[col * n + col]
                        let rowC = a + col * n
                        var r = col + 1
                        while r < n {
                            let rowR = a + r * n
                            let f = rowR[col] / d
                            if f != 0 {
                                var k = col
                                while k < n { rowR[k] -= f * rowC[k]; k += 1 }
                                b[r] -= f * b[col]
                            }
                            r += 1
                        }
                    }
                    var r = n - 1
                    while r >= 0 {
                        var s = -0.0
                        var k = r + 1
                        while k < n { s += a[r * n + k] * x[k]; k += 1 }
                        x[r] = (b[r] - s) / a[r * n + r]
                        r -= 1
                    }
                    return true
                }
            }
        }
        if !ok { return nil }
        return x.allSatisfy(\.isFinite) ? x : nil
    }
}

// MARK: - Tone mapping as a filter

/// Merge to HDR Pro's 16/8-bit conversion (photocraft `hdr::tone_map`) as a filter: linear
/// radiance in, display-encoded 0…1 out, the reference bounds mapped as one image.
public struct HDRToneMap: Filter, Hashable {
    public var method: HDRToneMethod
    public init(method: HDRToneMethod) { self.method = method }

    public var label: String { "HDR Tone Mapping" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }
    public var gpuChannels: GPUChannels { .joint }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let b = ctx.bounds
        var px = ToneKit.rgbaPixels(src, b, ctx)
        ToneKit.toneMap(&px, w: b.width, h: b.height, method: method)
        return ToneKit.writeRGBA(px, b, src, out, ctx)
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        try ToneKit.encodeToneMap(method, pass)
    }
}
