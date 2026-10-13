// Port of photocraft-algo (crates/algo/src/segment/gmm.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Gaussian mixture colour models with full 3×3 covariances: k-means++ seeding (Arthur &
// Vassilvitskii, SODA 2007), Lloyd iterations, then a few EM steps; GrabCut's per-iteration update
// (assign every sample to its most likely component, re-estimate) is `refit`. Covariances get a
// small ridge so flat colour areas stay well-conditioned. Double precision as photocraft.

import Foundation
import PCFoundation

/// One Gaussian component.
public struct GMMComponent: Sendable, Equatable {
    public var weight: Float
    public var mean: SIMD3<Float>
    public var cov: [[Float]]
    var inv: [[Double]]
    /// ln(weight) − ½ ln det Σ − 3/2 ln 2π.
    var logNorm: Double

    init?(weight: Double, mean: [Double], cov: [[Double]], reg: Double) {
        var c = cov
        for i in 0..<3 { c[i][i] += reg }
        let det = c[0][0] * (c[1][1] * c[2][2] - c[1][2] * c[2][1]) - c[0][1] * (c[1][0] * c[2][2] - c[1][2] * c[2][0])
            + c[0][2] * (c[1][0] * c[2][1] - c[1][1] * c[2][0])
        if det <= 1e-30 || weight <= 0 { return nil }
        inv = [
            [(c[1][1] * c[2][2] - c[1][2] * c[2][1]) / det, (c[0][2] * c[2][1] - c[0][1] * c[2][2]) / det, (c[0][1] * c[1][2] - c[0][2] * c[1][1]) / det],
            [(c[1][2] * c[2][0] - c[1][0] * c[2][2]) / det, (c[0][0] * c[2][2] - c[0][2] * c[2][0]) / det, (c[0][2] * c[1][0] - c[0][0] * c[1][2]) / det],
            [(c[1][0] * c[2][1] - c[1][1] * c[2][0]) / det, (c[0][1] * c[2][0] - c[0][0] * c[2][1]) / det, (c[0][0] * c[1][1] - c[0][1] * c[1][0]) / det],
        ]
        logNorm = log(weight) - 0.5 * log(det) - 1.5 * log(2 * Double.pi)
        self.weight = Float(weight)
        self.mean = SIMD3(Float(mean[0]), Float(mean[1]), Float(mean[2]))
        self.cov = c.map { $0.map { Float($0) } }
    }

    /// ln(weight · N(z; μ, Σ)).
    @inline(__always)
    public func logWeighted(_ z: SIMD3<Float>) -> Double {
        let d0 = Double(z.x - mean.x), d1 = Double(z.y - mean.y), d2 = Double(z.z - mean.z)
        let m = inv
        let q = d0 * (m[0][0] * d0 + m[0][1] * d1 + m[0][2] * d2) + d1 * (m[1][0] * d0 + m[1][1] * d1 + m[1][2] * d2)
            + d2 * (m[2][0] * d0 + m[2][1] * d1 + m[2][2] * d2)
        return logNorm - 0.5 * q
    }
}

/// A Gaussian mixture over RGB (0…1) — photocraft `Gmm`.
public struct GMM: Sendable, Equatable {
    public var comps: [GMMComponent]
    /// Ridge added to covariance diagonals.
    public var reg: Float

    /// Default covariance ridge: about one 8-bit level of standard deviation.
    public static let defaultReg: Float = 2e-5

    struct Acc {
        var n = 0.0
        var s = [Double](repeating: 0, count: 3)
        var ss = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)

        mutating func add(_ z: SIMD3<Float>, _ w: Double) {
            let zz = [Double(z.x), Double(z.y), Double(z.z)]
            n += w
            for i in 0..<3 {
                s[i] += w * zz[i]
                for j in 0..<3 { ss[i][j] += w * zz[i] * zz[j] }
            }
        }

        func component(_ total: Double, _ reg: Float) -> GMMComponent? {
            if n <= 0 { return nil }
            let m = s.map { $0 / n }
            var c = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
            for i in 0..<3 { for j in 0..<3 { c[i][j] = ss[i][j] / n - m[i] * m[j] } }
            return GMMComponent(weight: n / total, mean: m, cov: c, reg: Double(reg))
        }
    }

    /// Fits `k` components (fewer without enough distinct samples); nil without samples.
    public static func fit(_ samples: [SIMD3<Float>], k: Int, reg: Float) -> GMM? { fitEM(samples, k: k, reg: reg, emIters: 3) }

    /// `fit` with an explicit number of EM iterations after k-means.
    public static func fitEM(_ samples: [SIMD3<Float>], k k0: Int, reg: Float, emIters: Int) -> GMM? {
        if samples.isEmpty { return nil }
        let k = min(max(k0, 1), samples.count)
        let centers = kmeans(samples, k: k, iters: 10)
        let labels = samples.map { nearest(centers, $0) }
        guard var g = fromLabels(samples, labels, k: centers.count, reg: reg) else { return nil }
        for _ in 0..<emIters { g = g.emStep(samples) ?? g }
        return g
    }

    /// Component statistics from hard assignments.
    public static func fromLabels(_ samples: [SIMD3<Float>], _ labels: [Int], k: Int, reg: Float) -> GMM? {
        var acc = [Acc](repeating: Acc(), count: k)
        for (z, l) in zip(samples, labels) { acc[l].add(z, 1) }
        let total = Double(samples.count)
        let comps = acc.compactMap { $0.component(total, reg) }
        return comps.isEmpty ? nil : GMM(comps: comps, reg: reg)
    }

    /// One EM step (soft responsibilities).
    func emStep(_ samples: [SIMD3<Float>]) -> GMM? {
        let k = comps.count
        var acc = [Acc](repeating: Acc(), count: k)
        var lw = [Double](repeating: 0, count: k)
        for z in samples {
            var mx = -Double.greatestFiniteMagnitude
            for c in 0..<k { lw[c] = comps[c].logWeighted(z); mx = Double.maximum(mx, lw[c]) }
            var sum = 0.0
            for c in 0..<k { lw[c] = exp(lw[c] - mx); sum += lw[c] }
            for c in 0..<k {
                let r = lw[c] / sum
                if r > 1e-6 { acc[c].add(z, r) }
            }
        }
        let total = Double(samples.count)
        let cs = acc.compactMap { $0.component(total, reg) }
        return cs.isEmpty ? nil : GMM(comps: cs, reg: reg)
    }

    /// GrabCut update: assign each sample to its most likely component and re-estimate.
    public func refit(_ samples: [SIMD3<Float>]) -> GMM? {
        GMM.fromLabels(samples, samples.map { componentOf($0) }, k: comps.count, reg: reg)
    }

    /// Index of the most likely component for `z`.
    public func componentOf(_ z: SIMD3<Float>) -> Int {
        var best = 0
        var bv = -Double.greatestFiniteMagnitude
        for (i, c) in comps.enumerated() {
            let v = c.logWeighted(z)
            if v > bv { bv = v; best = i }
        }
        return best
    }

    /// ln p(z) (log-sum-exp over at most 16 components).
    public func logProb(_ z: SIMD3<Float>) -> Double {
        var mx = -Double.greatestFiniteMagnitude
        let n = min(comps.count, 16)
        var vals = [Double](repeating: 0, count: 16)
        for i in 0..<n { vals[i] = comps[i].logWeighted(z); mx = Double.maximum(mx, vals[i]) }
        var s = 0.0
        for i in 0..<n { s += exp(vals[i] - mx) }
        return mx + log(s)
    }

    /// −ln p(z), clamped to a finite range.
    public func negLog(_ z: SIMD3<Float>) -> Float {
        let v = -logProb(z)
        return Float(v.isNaN ? v : min(max(v, -50), 200))
    }

    static func nearest(_ centers: [SIMD3<Float>], _ z: SIMD3<Float>) -> Int {
        var best = 0
        var bd = Float.greatestFiniteMagnitude
        for (i, c) in centers.enumerated() {
            let d = QuickSelection.d2(c, z)
            if d < bd { bd = d; best = i }
        }
        return best
    }

    /// k-means with k-means++ seeding (deterministic seed); drops empty clusters.
    public static func kmeans(_ samples: [SIMD3<Float>], k: Int, iters: Int) -> [SIMD3<Float>] {
        var rng = SegmentKit.Rng(0x5EED &+ UInt64(samples.count))
        var centers = [samples[Int(rng.nextU64() % UInt64(samples.count))]]
        var dist = samples.map { QuickSelection.d2($0, centers[0]) }
        while centers.count < k {
            var total = 0.0
            for d in dist { total += Double(d) }
            if total <= 1e-12 { break }
            var t = Double(rng.f32()) * total
            var pick = samples.count - 1
            for (i, d) in dist.enumerated() {
                t -= Double(d)
                if t <= 0 { pick = i; break }
            }
            let c = samples[pick]
            centers.append(c)
            for i in 0..<dist.count { dist[i] = Float.minimum(dist[i], QuickSelection.d2(samples[i], c)) }
        }
        for _ in 0..<iters {
            var sums = [(SIMD3<Double>, Int)](repeating: (.zero, 0), count: centers.count)
            for z in samples {
                let i = nearest(centers, z)
                sums[i].0.x += Double(z.x); sums[i].0.y += Double(z.y); sums[i].0.z += Double(z.z)
                sums[i].1 += 1
            }
            let new = sums.filter { $0.1 > 0 }.map { s, n in SIMD3(Float(s.x / Double(n)), Float(s.y / Double(n)), Float(s.z / Double(n))) }
            let done = new == centers
            centers = new
            if done { break }
        }
        return centers
    }
}
