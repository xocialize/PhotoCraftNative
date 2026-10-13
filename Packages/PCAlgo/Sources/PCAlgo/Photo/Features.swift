// Port of photocraft-algo (crates/algo/src/features.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image registration for Edit › Auto-Align Layers: Harris corners (C. Harris, M. Stephens, Alvey
// 1988: structure tensor det − k·trace², box-approximated Gaussian window, non-maximum
// suppression, minimum spacing), steered BRIEF descriptors (Rublee et al., ORB, ICCV 2011: 256
// comparisons on a smoothed 31×31 patch rotated by the intensity-centroid orientation), Hamming
// matching with Lowe's ratio test and a mutual-nearest check, and RANSAC (Fischler & Bolles 1981)
// over translation / similarity / homography (Hartley-normalised DLT), refit to the inliers.
//
// Deterministic (fixed-seed RNG). Images are `w × h` luminance in 0…1. The Harris response map
// (Sobel, structure tensor, the four running-sum box passes, the response and its candidate
// maxima) has a Metal path (`FeaturesGPU.swift`) that reproduces it bit for bit; corner
// selection, descriptors, matching and fitting are sequential / per-corner and stay on the CPU.

import Foundation
import PCFoundation

/// Corners, binary descriptors, matching and robust model fitting (photocraft `features`).
public enum Features {
    /// A detected corner.
    public struct Corner: Hashable, Sendable {
        public var x: Float
        public var y: Float
        public var score: Float
        public init(x: Float, y: Float, score: Float) { self.x = x; self.y = y; self.score = score }
    }

    /// A 256-bit descriptor.
    public typealias Descriptor = SIMD4<UInt64>

    /// Model fitted by `ransac`.
    public enum Model: String, Codable, Sendable, Hashable, CaseIterable {
        case translation
        /// Rotation, uniform scale and translation.
        case similarity
        case homography

        var minPoints: Int {
            switch self { case .translation: 1; case .similarity: 2; case .homography: 4 }
        }
    }

    /// Patch radius used by descriptors (corners closer than this to the border are dropped).
    public static let patchRadius = 15

    // MARK: - Harris

    /// The Harris response `det − 0.04·trace²` of the box-smoothed structure tensor (the Sobel
    /// gradients' products, each blurred by two radius-1 running-sum box passes).
    static func harrisResponse(_ w: Int, _ h: Int, _ img: [Float]) -> [Float] {
        var xx = [Float](repeating: 0, count: w * h), yy = xx, xy = xx
        img.withUnsafeBufferPointer { ib in
            xx.withUnsafeMutableBufferPointer { a in
                yy.withUnsafeMutableBufferPointer { b in
                    xy.withUnsafeMutableBufferPointer { c in
                        let ip = UnsafeSendable(ib.baseAddress!), ap = UnsafeSendable(a.baseAddress!)
                        let bp = UnsafeSendable(b.baseAddress!), cp = UnsafeSendable(c.baseAddress!)
                        PhotoKit.parRows(max(h - 2, 0)) { yi in
                            let y = yi + 1, im = ip.value
                            for x in 1..<(w - 1) {
                                @inline(__always) func p(_ dx: Int, _ dy: Int) -> Float { im[(y + dy) * w + x + dx] }
                                let gx = (p(1, -1) + 2 * p(1, 0) + p(1, 1)) - (p(-1, -1) + 2 * p(-1, 0) + p(-1, 1))
                                let gy = (p(-1, 1) + 2 * p(0, 1) + p(1, 1)) - (p(-1, -1) + 2 * p(0, -1) + p(1, -1))
                                let i = y * w + x
                                ap.value[i] = gx * gx
                                bp.value[i] = gy * gy
                                cp.value[i] = gx * gy
                            }
                        }
                    }
                }
            }
        }
        let sxx = PhotoKit.boxBlur(w, h, PhotoKit.boxBlur(w, h, xx, 1), 1)
        let syy = PhotoKit.boxBlur(w, h, PhotoKit.boxBlur(w, h, yy, 1), 1)
        let sxy = PhotoKit.boxBlur(w, h, PhotoKit.boxBlur(w, h, xy, 1), 1)
        return (0..<(w * h)).map { i in
            let t = sxx[i] + syy[i]
            return sxx[i] * syy[i] - sxy[i] * sxy[i] - 0.04 * (t * t)
        }
    }

    /// Whether `(x, y)` is a corner candidate of the response map: at least 1 % of the peak and
    /// no smaller than any of its 8 neighbours.
    @inline(__always)
    static func isCandidate(_ r: UnsafeBufferPointer<Float>, _ w: Int, _ x: Int, _ y: Int, _ peak: Float) -> Bool {
        let v = r[y * w + x]
        if v < peak * 0.01 { return false }
        for dy in -1...1 {
            for dx in -1...1 where !(dx == 0 && dy == 0) {
                if !(r[(y + dy) * w + x + dx] <= v) { return false }
            }
        }
        return true
    }

    /// Harris corners: at most `max` corners at least `minDist` pixels apart, strongest first,
    /// only where `valid` (if given) is true for the whole descriptor patch (photocraft `harris`).
    public static func harris(width w: Int, height h: Int, _ img: [Float], max maxCount: Int, minDist: Float, valid: [Bool]? = nil,
                              on backend: Backend = .cpu) throws -> [Corner] {
        if w < 2 * patchRadius + 3 || h < 2 * patchRadius + 3 { return [] }
        let m = patchRadius + 1
        // (x, y, score) of the candidates: the response maps' local maxima above 1 % of the peak.
        let raw: [(Int, Int, Float)] = try PhotoKit.run(backend, "Features.harris", fits: PhotoKit.gpuFits(w, h, 4),
                                                        gpu: { try FeaturesGPU.candidates(w, h, img, m) },
                                                        cpu: { candidatesCPU(w, h, img, m) })
        var cand: [Corner] = []
        cand.reserveCapacity(raw.count)
        for (x, y, v) in raw {
            if let ok = valid {
                var all = true
                var yy = y - patchRadius
                outer: while yy <= y + patchRadius {
                    var xx = x - patchRadius
                    while xx <= x + patchRadius {
                        if !ok[yy * w + xx] { all = false; break outer }
                        xx += 5
                    }
                    yy += 5
                }
                if !all { continue }
            }
            cand.append(Corner(x: Float(x), y: Float(y), score: v))
        }
        // Score descending, then y, then x (a total order: positions are unique).
        cand.sort { a, b in
            if PhotoKit.totalLess(b.score, a.score) { return true }
            if PhotoKit.totalLess(a.score, b.score) { return false }
            if a.y != b.y { return a.y < b.y }
            return a.x < b.x
        }
        // Minimum spacing via a coarse occupancy grid.
        let cell = PhotoKit.fmax(minDist, 1)
        let gw = PhotoKit.usize((Float(w) / cell).rounded(.up)) + 1, gh = PhotoKit.usize((Float(h) / cell).rounded(.up)) + 1
        var grid = [[(Float, Float)]](repeating: [], count: gw * gh)
        var out: [Corner] = []
        for c in cand {
            let gx = PhotoKit.usize(c.x / cell), gy = PhotoKit.usize(c.y / cell)
            var near = false
            check: for yy in max(gy - 1, 0)...min(gy + 1, gh - 1) {
                for xx in max(gx - 1, 0)...min(gx + 1, gw - 1) {
                    for (px, py) in grid[yy * gw + xx] where hypotf(px - c.x, py - c.y) < minDist { near = true; break check }
                }
            }
            if near { continue }
            grid[gy * gw + gx].append((c.x, c.y))
            out.append(c)
            if out.count >= maxCount { break }
        }
        return out
    }

    /// The CPU candidates (row-major order).
    static func candidatesCPU(_ w: Int, _ h: Int, _ img: [Float], _ m: Int) -> [(Int, Int, Float)] {
        let r = harrisResponse(w, h, img)
        let peak = r.reduce(Float(0)) { PhotoKit.fmax($0, $1) }
        if peak <= 0 { return [] }
        var out: [(Int, Int, Float)] = []
        r.withUnsafeBufferPointer { rb in
            for y in m..<(h - m) {
                for x in m..<(w - m) where isCandidate(rb, w, x, y, peak) { out.append((x, y, rb[y * w + x])) }
            }
        }
        return out
    }

    // MARK: - Descriptors

    /// The 256 BRIEF test pairs (fixed, Gaussian around the centre, σ = 31/5, clipped to ±13).
    static let pairs: [SIMD4<Float>] = {
        var rng = PhotoKit.Rng(0x0B21_EF00)
        func gauss() -> Float {
            let u = PhotoKit.dmax(rng.unit(), 1e-12), v = rng.unit()
            return Float(PhotoKit.clamp((-2.0 * log(u)).squareRoot() * cos(6.283185307179586 * v) * 31.0 / 5.0, -13, 13))
        }
        return (0..<256).map { _ in
            let a = gauss(), b = gauss(), c = gauss(), d = gauss()
            return SIMD4(a, b, c, d)
        }
    }()

    /// Steered-BRIEF descriptors for `corners` (orientation from the intensity centroid unless
    /// `upright`), one per corner, in order (photocraft `describe`).
    public static func describe(width w: Int, height h: Int, _ img: [Float], corners: [Corner], upright: Bool) -> [Descriptor] {
        let smooth = PhotoKit.boxBlur(w, h, img, 2)
        let pr = pairs
        return smooth.withUnsafeBufferPointer { sb in
            let sp = UnsafeSendable(sb.baseAddress!)
            @inline(__always) func at(_ x: Float, _ y: Float) -> Float {
                let xi = min(max(PhotoKit.i64(Double(x.rounded())), 0), w - 1)
                let yi = min(max(PhotoKit.i64(Double(y.rounded())), 0), h - 1)
                return sp.value[yi * w + xi]
            }
            return PhotoKit.parMap(corners.count) { ci in
                let c = corners[ci]
                var s: Float = 0, co: Float = 1
                if !upright {
                    var m10: Float = 0, m01: Float = 0
                    let r = patchRadius
                    for dy in -r...r {
                        for dx in -r...r where dx * dx + dy * dy <= r * r {
                            let v = at(c.x + Float(dx), c.y + Float(dy))
                            m10 += Float(dx) * v
                            m01 += Float(dy) * v
                        }
                    }
                    let a = atan2f(m01, m10)
                    s = sinf(a); co = cosf(a)
                }
                var d = Descriptor(repeating: 0)
                for (i, p) in pr.enumerated() {
                    let ax = c.x + p.x * co - p.y * s, ay = c.y + p.x * s + p.y * co
                    let bx = c.x + p.z * co - p.w * s, by = c.y + p.z * s + p.w * co
                    if at(ax, ay) < at(bx, by) { d[i / 64] |= UInt64(1) << UInt64(i % 64) }
                }
                return d
            }
        }
    }

    /// Hamming distance of two descriptors.
    @inline(__always)
    public static func hamming(_ a: Descriptor, _ b: Descriptor) -> UInt32 {
        let x = a ^ b
        return UInt32(x[0].nonzeroBitCount + x[1].nonzeroBitCount + x[2].nonzeroBitCount + x[3].nonzeroBitCount)
    }

    /// Matches `(index in a, index in b)` passing the ratio test and the mutual-nearest check
    /// (photocraft `match_descriptors`).
    public static func matchDescriptors(_ a: [Descriptor], _ b: [Descriptor], ratio: Float) -> [(Int, Int)] {
        func best(_ d: Descriptor, _ set: [Descriptor]) -> (Int, UInt32, UInt32)? {
            var first = (Int.max, UInt32.max)
            var second = UInt32.max
            for (j, e) in set.enumerated() {
                let h = hamming(d, e)
                if h < first.1 { second = first.1; first = (j, h) } else if h < second { second = h }
            }
            return first.0 != Int.max ? (first.0, first.1, second) : nil
        }
        let matched: [(Int, Int)?] = PhotoKit.parMap(a.count) { i in
            guard let (j, d1, d2) = best(a[i], b) else { return nil }
            if d1 > 80 || (d2 != UInt32.max && Float(d1) > ratio * Float(d2)) { return nil }
            guard let (k, _, _) = best(b[j], a), k == i else { return nil }
            return (i, j)
        }
        return matched.compactMap { $0 }
    }

    // MARK: - Model fitting

    /// Hartley normalisation: centroid to the origin, mean distance √2.
    static func normaliser(_ pts: [SIMD2<Double>]) -> Homography {
        let n = Double(max(pts.count, 1))
        var sx = -0.0, sy = -0.0
        for p in pts { sx += p.x }
        for p in pts { sy += p.y }
        let cx = sx / n, cy = sy / n
        var sd = -0.0
        for p in pts { sd += hypot(p.x - cx, p.y - cy) }
        let d = sd / n
        let s = d > 1e-12 ? 2.0.squareRoot() / d : 1
        return Homography([s, 0, -s * cx, 0, s, -s * cy, 0, 0, 1])
    }

    /// Fits `model` mapping `src[i]` → `dst[i]` by least squares (exact for minimal sets).
    public static func fit(_ model: Model, src: [SIMD2<Double>], dst: [SIMD2<Double>]) -> Homography? {
        let n = src.count
        switch model {
        case .translation:
            if n == 0 { return nil }
            var tx = 0.0, ty = 0.0
            for (s, d) in zip(src, dst) { tx = tx + d.x - s.x; ty = ty + d.y - s.y }
            return Homography([1, 0, tx / Double(n), 0, 1, ty / Double(n), 0, 0, 1])
        case .similarity:
            if n < 2 { return nil }
            var rows: [([Double], Double)] = []
            for (s, d) in zip(src, dst) {
                rows.append(([s.x, -s.y, 1, 0], d.x))
                rows.append(([s.y, s.x, 0, 1], d.y))
            }
            guard let v = PhotoKit.leastSquares(rows, 4) else { return nil }
            return Homography([v[0], -v[1], v[2], v[1], v[0], v[3], 0, 0, 1])
        case .homography:
            if n < 4 { return nil }
            let ts = normaliser(src), td = normaliser(dst)
            var rows: [([Double], Double)] = []
            for (s, d) in zip(src, dst) {
                let (x, y) = ts.apply(s.x, s.y)
                let (u, v) = td.apply(d.x, d.y)
                rows.append(([x, y, 1, 0, 0, 0, -u * x, -u * y], u))
                rows.append(([0, 0, 0, x, y, 1, -v * x, -v * y], v))
            }
            guard let hv = PhotoKit.leastSquares(rows, 8) else { return nil }
            let hn = Homography([hv[0], hv[1], hv[2], hv[3], hv[4], hv[5], hv[6], hv[7], 1])
            guard let tdi = td.inverse() else { return nil }
            let m = tdi.mul(hn).mul(ts)
            let k = m.m[8]
            return abs(k) > 1e-12 ? Homography(m.m.map { $0 / k }) : nil
        }
    }

    /// The indices whose mapped source lies within `threshold` of its destination.
    static func inliers(_ h: Homography, _ src: [SIMD2<Double>], _ dst: [SIMD2<Double>], _ threshold: Double) -> [Int] {
        let m = h.m
        var out: [Int] = []
        for i in 0..<src.count {
            let x0 = src[i].x, y0 = src[i].y
            let wv = m[6] * x0 + m[7] * y0 + m[8]
            let x = (m[0] * x0 + m[1] * y0 + m[2]) / wv, y = (m[3] * x0 + m[4] * y0 + m[5]) / wv
            if x.isFinite && hypot(x - dst[i].x, y - dst[i].y) <= threshold { out.append(i) }
        }
        return out
    }

    /// RANSAC: the model with the most correspondences within `threshold` pixels after `iters`
    /// random minimal samples, refit to its inliers. Returns the model and the inlier indices
    /// (photocraft `ransac`).
    public static func ransac(_ model: Model, src: [SIMD2<Double>], dst: [SIMD2<Double>], iters: Int, threshold: Double, seed: UInt64)
        -> (Homography, [Int])? {
        let k = model.minPoints, n = src.count
        if n < k { return nil }
        var rng = PhotoKit.Rng(seed ^ 0xA11C_0DE5)
        var best: (Homography, [Int])? = nil
        for _ in 0..<max(iters, 1) {
            var idx: [Int] = []
            idx.reserveCapacity(k)
            while idx.count < k {
                let i = rng.below(n)
                if !idx.contains(i) { idx.append(i) }
                if n == k { idx = Array(0..<k) }
            }
            guard let h = fit(model, src: idx.map { src[$0] }, dst: idx.map { dst[$0] }) else { continue }
            let inl = inliers(h, src, dst, threshold)
            if best == nil || inl.count > best!.1.count { best = (h, inl) }
        }
        guard let (h, inl) = best, inl.count >= k else { return nil }
        let h2 = fit(model, src: inl.map { src[$0] }, dst: inl.map { dst[$0] }) ?? h
        let inl2 = inliers(h2, src, dst, threshold)
        return inl2.count >= inl.count ? (h2, inl2) : (h, inl)
    }

    /// Registers `moving` onto `reference` (both `w × h` luminance; optional validity masks for
    /// transparent areas): the model mapping `moving` coordinates to `reference` coordinates and
    /// the inlier count (photocraft `register`).
    public static func register(width w: Int, height h: Int, reference: [Float], moving: [Float], validReference: [Bool]? = nil,
                                validMoving: [Bool]? = nil, model: Model, on backend: Backend = .cpu) throws -> (Homography, Int)? {
        let upright = model == .translation
        let minDist = PhotoKit.clamp(Float(max(w, h)) / 60, 4, 24)
        let ca = try harris(width: w, height: h, reference, max: 600, minDist: minDist, valid: validReference, on: backend)
        let cb = try harris(width: w, height: h, moving, max: 600, minDist: minDist, valid: validMoving, on: backend)
        if ca.count < 4 || cb.count < 4 { return nil }
        let da = describe(width: w, height: h, reference, corners: ca, upright: upright)
        let db = describe(width: w, height: h, moving, corners: cb, upright: upright)
        let matches = matchDescriptors(db, da, ratio: 0.85)
        let src = matches.map { SIMD2(Double(cb[$0.0].x), Double(cb[$0.0].y)) }
        let dst = matches.map { SIMD2(Double(ca[$0.1].x), Double(ca[$0.1].y)) }
        let threshold = PhotoKit.clamp(Double(max(w, h)) / 400, 1.5, 4)
        guard let (hm, inl) = ransac(model, src: src, dst: dst, iters: 1000, threshold: threshold, seed: 7) else { return nil }
        return inl.count >= max(model.minPoints, 6) ? (hm, inl.count) : nil
    }
}
