// Port of photocraft-algo (crates/algo/src/direct.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Direct (intensity-based) registration for Edit › Auto-Align Layers, for layers that nearly
// coincide (a focus or exposure bracket, a burst): the target is registered to the reference
// coarse-to-fine on a Gaussian pyramid of the luminance by a bounded Nelder–Mead search per
// level; the cost of a pose is the RMS of the mean-removed difference between the reference and
// the target warped by it (cubic B-spline) over the pixels both cover. The pose is resolution
// independent (shifts as fractions of the size, a scale, an angle, aspect/shear, perspective).
//
// CPU only: the cost is accumulated in f64 (Σr, Σt, Σr², Σt², Σrt over millions of pixels, whose
// central moments cancel to a few digits near the optimum) and every Nelder–Mead step compares
// costs, so a float GPU cost would steer the simplex down a different path; Metal has no f64.
// The per-row sums run in parallel (photocraft's `par_map`) and fold in row order.

import Foundation
import PCFoundation

/// Intensity-based registration (photocraft `direct`).
public enum DirectAlign {
    /// A layer's transform onto the reference, about the layer's centre (photocraft `Pose`).
    public struct Pose: Hashable, Sendable, Codable {
        /// Shift, as a fraction of the width.
        public var dx: Double
        /// Shift, as a fraction of the height.
        public var dy: Double
        public var scale: Double
        /// Rotation in radians.
        public var rot: Double
        /// Vertical over horizontal scale (1 = isotropic).
        public var aspect: Double
        /// Horizontal shear per unit of height (0 = none).
        public var shear: Double
        /// Perspective: the divisor `1 + px·u/w + py·v/h` over the centred pixel `(u, v)`.
        public var px: Double
        public var py: Double

        public init(dx: Double = 0, dy: Double = 0, scale: Double = 1, rot: Double = 0, aspect: Double = 1, shear: Double = 0,
                    px: Double = 0, py: Double = 0) {
            self.dx = dx; self.dy = dy; self.scale = scale; self.rot = rot; self.aspect = aspect; self.shear = shear; self.px = px; self.py = py
        }

        /// The number of parameters.
        public static let count = 8
        public static let identity = Pose()
        /// The search box's half-width around the start, per parameter.
        static let span: [Double] = [0.10, 0.10, 0.10, 0.087_266_462_599_716_47, 0.05, 0.05, 0.05, 0.05]

        public var vector: [Double] { [dx, dy, scale, rot, aspect, shear, px, py] }

        public init(vector v: [Double]) {
            self.init(dx: v[0], dy: v[1], scale: v[2], rot: v[3], aspect: v[4], shear: v[5], px: v[6], py: v[7])
        }

        /// Which parameters a search over `motion` may move.
        public static func free(_ motion: Panorama.Motion) -> [Bool] {
            switch motion {
            case .translation: [true, true, false, false, false, false, false, false]
            case .euclidean: [true, true, false, true, false, false, false, false]
            case .similarity: [true, true, true, true, false, false, false, false]
            case .homography: [Bool](repeating: true, count: 8)
            }
        }

        /// The homography mapping the layer's pixels onto the reference's (photocraft `Pose::matrix`).
        public func matrix(width w: Int, height h: Int) -> Homography {
            let cx = Double(w) / 2, cy = Double(h) / 2
            let c = cos(rot), s = sin(rot)
            let sc = scale
            let a = sc * c, b = sc * (c * shear - s * aspect), d = sc * s, e = sc * (s * shear + c * aspect)
            let gx = px / Double(w), gy = py / Double(h)
            let a2 = a + cx * gx, b2 = b + cx * gy, d2 = d + cy * gx, e2 = e + cy * gy
            let tx = cx + dx * Double(w) - (a2 * cx + b2 * cy)
            let ty = cy + dy * Double(h) - (d2 * cx + e2 * cy)
            return Homography([a2, b2, tx, d2, e2, ty, gx, gy, 1.0 - gx * cx - gy * cy])
        }
    }

    /// A luminance plane with, where the layer does not cover its whole area, its coverage.
    public struct Plane: Sendable {
        public var w: Int
        public var h: Int
        public var luma: [Float]
        public var valid: [Bool]?
        public init(w: Int, h: Int, luma: [Float], valid: [Bool]? = nil) { self.w = w; self.h = h; self.luma = luma; self.valid = valid }
    }

    /// The outcome of `register`.
    public struct Registration: Hashable, Sendable {
        public var pose: Pose
        /// The pose as a homography of the target's pixels onto the reference's.
        public var h: Homography
        /// The cost at the pose (finest level searched).
        public var rms: Double
        /// Pixels of the finest level searched that both layers cover at the pose.
        public var overlap: Int
        /// Pearson correlation of the reference with the warped target over those pixels.
        public var correlation: Double
    }

    /// One pyramid level.
    struct Lvl {
        var luma: [Float]
        var valid: [Bool]?
        var w: Int
        var h: Int
    }

    static let k: [Float] = [1.0 / 16.0, 4.0 / 16.0, 6.0 / 16.0, 4.0 / 16.0, 1.0 / 16.0]

    /// Gaussian REDUCE of a plane and its coverage; a reduced pixel is covered when more than half
    /// its support is.
    static func reduce(_ l: Lvl) -> Lvl {
        let w = (l.w + 1) / 2, h = (l.h + 1) / 2
        func pass(_ src: [Float]) -> [Float] {
            var tmp = [Float](repeating: 0, count: w * l.h)
            src.withUnsafeBufferPointer { s in
                tmp.withUnsafeMutableBufferPointer { t in
                    for y in 0..<l.h {
                        for x in 0..<w {
                            var o: Float = -0.0
                            for kk in 0..<5 { o += k[kk] * s[y * l.w + min(max(2 * x + kk - 2, 0), l.w - 1)] }
                            t[y * w + x] = o
                        }
                    }
                }
            }
            var out = [Float](repeating: 0, count: w * h)
            tmp.withUnsafeBufferPointer { t in
                out.withUnsafeMutableBufferPointer { o in
                    for y in 0..<h {
                        for kk in 0..<5 {
                            let sy = min(max(2 * y + kk - 2, 0), l.h - 1)
                            for x in 0..<w { o[y * w + x] += k[kk] * t[sy * w + x] }
                        }
                    }
                }
            }
            return out
        }
        let luma = pass(l.luma)
        let valid = l.valid.map { v in pass(v.map { $0 ? 1 : 0 }).map { $0 > 0.5 } }
        return Lvl(luma: luma, valid: valid, w: w, h: h)
    }

    /// The search pyramid: level 0 is the plane, each next level half its size, while the height
    /// exceeds 64 and the width 8.
    static func levels(_ p: Plane) -> [Lvl] {
        var out = [Lvl(luma: p.luma, valid: p.valid, w: p.w, h: p.h)]
        while let last = out.last {
            if last.h <= 64 || last.w <= 8 { break }
            out.append(reduce(last))
        }
        return out
    }

    /// The cubic B-spline (4 taps) at fraction `t`.
    @inline(__always)
    static func spline4(_ t: Double) -> (Double, Double, Double, Double) {
        ((((-1.0 / 3.0) * t + 0.8) * t - 0.466_666_67) * t,
         ((t - 1.8) * t - 0.2) * t + 1.0,
         ((1.2 - t) * t + 0.8) * t,
         (((1.0 / 3.0) * t - 0.2) * t - 0.133_333_34) * t)
    }

    /// `src` sampled at `(sx, sy)` with the cubic B-spline, edge-clamped (photocraft `sample`).
    static func sample(_ src: [Float], _ w: Int, _ h: Int, _ sx: Double, _ sy: Double) -> Float {
        src.withUnsafeBufferPointer { sampleFast($0.baseAddress!, w, h, sx, sy) }
    }

    @inline(__always)
    static func sampleFast(_ src: UnsafePointer<Float>, _ w: Int, _ h: Int, _ sx: Double, _ sy: Double) -> Float {
        let x0f = sx.rounded(.down), y0f = sy.rounded(.down)
        let wx = spline4(sx - x0f), wy = spline4(sy - y0f)
        let x0 = PhotoKit.i64(x0f), y0 = PhotoKit.i64(y0f)
        let xa = min(max(x0 &- 1, 0), w - 1), xb = min(max(x0, 0), w - 1), xc = min(max(x0 &+ 1, 0), w - 1), xd = min(max(x0 &+ 2, 0), w - 1)
        @inline(__always) func row(_ j: Int) -> Double {
            let yy = min(max(y0 &+ j &- 1, 0), h - 1)
            let p = src + yy * w
            var r = 0.0
            r += wx.0 * Double(p[xa])
            r += wx.1 * Double(p[xb])
            r += wx.2 * Double(p[xc])
            r += wx.3 * Double(p[xd])
            return r
        }
        var acc = 0.0
        acc += wy.0 * row(0)
        acc += wy.1 * row(1)
        acc += wy.2 * row(2)
        acc += wy.3 * row(3)
        return Float(acc)
    }

    /// Whether the target covers the source point (nearest pixel of its coverage).
    @inline(__always)
    static func covered(_ valid: UnsafeBufferPointer<Bool>?, _ w: Int, _ sx: Double, _ sy: Double) -> Bool {
        guard let v = valid else { return true }
        return v[PhotoKit.usize(sy + 0.5) * w + PhotoKit.usize(sx + 0.5)]
    }

    /// The cost of `pose`: the RMS of `reference − target ∘ pose`, the mean removed, over the
    /// reference pixels both cover; 1e9 when fewer than 16 do. Also the overlap and the
    /// correlation (photocraft `cost`).
    static func cost(_ reference: Lvl, _ target: Lvl, _ pose: Pose) -> (Double, Int, Double) {
        guard let inv = pose.matrix(width: target.w, height: target.h).inverse() else { return (1e9, 0, 0) }
        let m = inv.m
        let affine = m[6] == 0 && m[7] == 0 && m[8] == 1
        let xmax = Double(target.w - 1), ymax = Double(target.h - 1)
        let tw = target.w, th = target.h, rw = reference.w
        typealias Sums = (Double, Double, Double, Double, Double, Int)
        let rows: [Sums] = reference.luma.withUnsafeBufferPointer { rl in
            target.luma.withUnsafeBufferPointer { tl in
                let rp = UnsafeSendable(rl), tp = UnsafeSendable(tl.baseAddress!)
                return withOptionalBuffer(reference.valid) { rv in
                    withOptionalBuffer(target.valid) { tv in
                        let rvp = UnsafeSendable(rv), tvp = UnsafeSendable(tv)
                        return PhotoKit.parMap(reference.h) { y -> Sums in
                            var sr = 0.0, st = 0.0, sr2 = 0.0, st2 = 0.0, srt = 0.0, cnt = 0
                            let yf = Double(y)
                            let ax0 = m[1] * yf + m[2], ay0 = m[4] * yf + m[5], adx = m[0], ady = m[3]
                            for x in 0..<rw {
                                if let v = rvp.value, !v[y * rw + x] { continue }
                                let sx: Double, sy: Double
                                if affine {
                                    sx = ax0 + adx * Double(x); sy = ay0 + ady * Double(x)
                                } else {
                                    let xf = Double(x)
                                    let wv = m[6] * xf + m[7] * yf + m[8]
                                    sx = (m[0] * xf + m[1] * yf + m[2]) / wv; sy = (m[3] * xf + m[4] * yf + m[5]) / wv
                                }
                                let inside = sx >= 0 && sx <= xmax && sy >= 0 && sy <= ymax
                                if !inside || !covered(tvp.value, tw, sx, sy) { continue }
                                let r = Double(rp.value[y * rw + x]), t = Double(sampleFast(tp.value, tw, th, sx, sy))
                                sr += r; st += t; sr2 += r * r; st2 += t * t; srt += r * t; cnt += 1
                            }
                            return (sr, st, sr2, st2, srt, cnt)
                        }
                    }
                }
            }
        }
        var sr = 0.0, st = 0.0, sr2 = 0.0, st2 = 0.0, srt = 0.0, cnt = 0
        for b in rows { sr = sr + b.0; st = st + b.1; sr2 = sr2 + b.2; st2 = st2 + b.3; srt = srt + b.4; cnt = cnt + b.5 }
        if cnt < 16 { return (1e9, cnt, 0) }
        let n = Double(cnt)
        let vr = PhotoKit.dmax(sr2 - sr * sr / n, 0), vt = PhotoKit.dmax(st2 - st * st / n, 0), cov = srt - sr * st / n
        let rms = PhotoKit.dmax((vr + vt - 2 * cov) / n, 0).squareRoot()
        let correlation = vr > 0 && vt > 0 ? PhotoKit.clamp(cov / (vr * vt).squareRoot(), -1, 1) : 0
        return (rms, cnt, correlation)
    }

    static func withOptionalBuffer<R>(_ v: [Bool]?, _ body: (UnsafeBufferPointer<Bool>?) -> R) -> R {
        guard let v else { return body(nil) }
        return v.withUnsafeBufferPointer { body($0) }
    }

    /// Full-resolution pixels a point at the layer's edge moves per unit of each parameter.
    static func paramGain(_ w: Int, _ h: Int) -> [Double] {
        let wf = Double(w), hf = Double(h)
        let r = max(wf, hf) / 2
        return [wf, hf, r, r, hf / 2, hf / 2, wf / 4, hf / 4]
    }

    static let stepPx = 1.0
    static let tolPx = 0.1

    /// The search's first step and stopping size per free parameter at pyramid level `lvl`.
    static func levelSteps(_ free: [Int], _ lvl: Int, _ w: Int, _ h: Int) -> ([Double], [Double]) {
        let gain = paramGain(w, h)
        let px = Double(UInt64(1) << UInt64(min(lvl, 60)))
        return (free.map { stepPx * px / gain[$0] }, free.map { tolPx * px / gain[$0] })
    }

    /// Nelder–Mead's stopping rule on a simplex sorted by `fv`.
    static func converged(_ simplex: [[Double]], _ fv: [Double], _ tol: [Double]) -> Bool {
        let n = tol.count
        guard let first = fv.first, n < fv.count, let best = simplex.first else { return true }
        let last = fv[n]
        if abs(last - first) > 1e-4 * (1 + abs(first)) { return false }
        return simplex.dropFirst().allSatisfy { v in (0..<n).allSatisfy { abs(v[$0] - best[$0]) <= tol[$0] } }
    }

    /// Bounded Nelder–Mead from `x0` over `[lo, hi]` (photocraft `nelder_mead`): the first simplex
    /// moves `x0` by `step[k]` along each axis; stops when the values agree to 1e-4 relative and
    /// the vertices lie within `tol[k]` of the best, or after 200 iterations.
    static func nelderMead(_ f: ([Double]) -> Double, _ x0: [Double], _ lo: [Double], _ hi: [Double], _ step: [Double], _ tol: [Double]) -> [Double] {
        let n = x0.count
        if n == 0 { return [] }
        func clampV(_ v: inout [Double]) { for k in 0..<n { v[k] = PhotoKit.clamp(v[k], lo[k], hi[k]) } }
        var simplex: [[Double]] = [x0]
        for k in 0..<n {
            var v = x0
            v[k] += step[k]
            clampV(&v)
            simplex.append(v)
        }
        var fv = simplex.map(f)
        let (alpha, gamma, rho, sigma) = (1.0, 2.0, 0.5, 0.5)
        for _ in 0..<200 {
            let idx = PhotoKit.stableOrder(n + 1) { PhotoKit.totalLess(fv[$0], fv[$1]) }
            simplex = idx.map { simplex[$0] }
            fv = idx.map { fv[$0] }
            if converged(simplex, fv, tol) { break }
            var c = [Double](repeating: 0, count: n)
            for v in simplex[..<n] { for k in 0..<n { c[k] += v[k] / Double(n) } }
            var xr = (0..<n).map { c[$0] + alpha * (c[$0] - simplex[n][$0]) }
            clampV(&xr)
            let fr = f(xr)
            if fr < fv[0] {
                var xe = (0..<n).map { c[$0] + gamma * (xr[$0] - c[$0]) }
                clampV(&xe)
                let fe = f(xe)
                if fe < fr { simplex[n] = xe; fv[n] = fe } else { simplex[n] = xr; fv[n] = fr }
            } else if fr < fv[n - 1] {
                simplex[n] = xr; fv[n] = fr
            } else {
                var xc = (0..<n).map { c[$0] + rho * (simplex[n][$0] - c[$0]) }
                clampV(&xc)
                let fc = f(xc)
                if fc < fv[n] {
                    simplex[n] = xc; fv[n] = fc
                } else {
                    let best = simplex[0]
                    for i in 1...n {
                        for k in 0..<n { simplex[i][k] = best[k] + sigma * (simplex[i][k] - best[k]) }
                        clampV(&simplex[i])
                        fv[i] = f(simplex[i])
                    }
                }
            }
        }
        // Rust `min_by(total_cmp)`: the first of equal minima.
        var bi = 0
        for i in 1...n where PhotoKit.totalLess(fv[i], fv[bi]) { bi = i }
        return simplex[bi]
    }

    /// Registers `target` to `reference` (planes of the same size) with the parameters `motion`
    /// moves, from `initial` (the previous layer's pose, or the identity), stopping `coarsen`
    /// levels short of full resolution (photocraft `register`).
    public static func register(reference: Plane, target: Plane, motion: Panorama.Motion, initial: Pose = .identity, coarsen: Int = 0) -> Registration {
        let w = target.w, h = target.h
        let pref = levels(reference), ptgt = levels(target)
        let n = min(pref.count, ptgt.count)
        let freeMask = Pose.free(motion)
        let free = (0..<Pose.count).filter { freeMask[$0] }
        let iv = initial.vector
        var cur = iv
        let lo = free.map { iv[$0] - Pose.span[$0] }, hi = free.map { iv[$0] + Pose.span[$0] }
        let finest = min(max(coarsen, 0), max(n - 1, 0))
        var rms = 1e9, overlap = 0, correlation = 0.0
        for lvl in stride(from: n - 1, through: finest, by: -1) {
            let rl = pref[lvl], tl = ptgt[lvl]
            let snap = cur
            let f = { (xf: [Double]) -> Double in
                var v = snap
                for (k, idx) in free.enumerated() { v[idx] = xf[k] }
                return cost(rl, tl, Pose(vector: v)).0
            }
            let x0 = free.map { cur[$0] }
            let (step, tol) = levelSteps(free, lvl, w, h)
            let best = nelderMead(f, x0, lo, hi, step, tol)
            for (k, idx) in free.enumerated() { cur[idx] = best[k] }
            (rms, overlap, correlation) = cost(rl, tl, Pose(vector: cur))
        }
        let pose = Pose(vector: cur)
        return Registration(pose: pose, h: pose.matrix(width: w, height: h), rms: rms, overlap: overlap, correlation: correlation)
    }

    /// `src` warped by `pose` into a plane of the same size with the cubic B-spline, and the
    /// coverage of the result (photocraft `warp`).
    public static func warp(_ src: Plane, pose: Pose) -> (luma: [Float], valid: [Bool]) {
        let w = src.w, h = src.h
        var out = [Float](repeating: 0, count: w * h)
        var valid = [Bool](repeating: false, count: w * h)
        guard let inv = pose.matrix(width: w, height: h).inverse() else { return (out, valid) }
        let m = inv.m
        let affine = m[6] == 0 && m[7] == 0 && m[8] == 1
        let xmax = Double(w - 1), ymax = Double(h - 1)
        src.luma.withUnsafeBufferPointer { sl in
            withOptionalBuffer(src.valid) { sv in
                out.withUnsafeMutableBufferPointer { ob in
                    valid.withUnsafeMutableBufferPointer { vb in
                        let sp = UnsafeSendable(sl.baseAddress!), svp = UnsafeSendable(sv)
                        let op = UnsafeSendable(ob.baseAddress!), vp = UnsafeSendable(vb.baseAddress!)
                        PhotoKit.parRows(h) { y in
                            let yf = Double(y)
                            for x in 0..<w {
                                let sx: Double, sy: Double
                                if affine {
                                    sx = (m[1] * yf + m[2]) + m[0] * Double(x); sy = (m[4] * yf + m[5]) + m[3] * Double(x)
                                } else {
                                    let xf = Double(x)
                                    let wv = m[6] * xf + m[7] * yf + m[8]
                                    sx = (m[0] * xf + m[1] * yf + m[2]) / wv; sy = (m[3] * xf + m[4] * yf + m[5]) / wv
                                }
                                let inside = sx >= 0 && sx <= xmax && sy >= 0 && sy <= ymax
                                vp.value[y * w + x] = inside && covered(svp.value, w, sx, sy)
                                if inside { op.value[y * w + x] = sampleFast(sp.value, w, h, sx, sy) }
                            }
                        }
                    }
                }
            }
        }
        return (out, valid)
    }
}
