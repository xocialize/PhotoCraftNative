// Port of photocraft-algo (crates/algo/src/poisson.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Gradient-domain ("Poisson") blending, the core of the Healing Brush and Spot Healing
// (Pérez, Gangnet & Blake, Poisson Image Editing, SIGGRAPH 2003): seamless cloning keeps the
// source's gradients and solves a membrane (Δh = 0) for the boundary mismatch. The Laplace
// equation is solved by cascadic multigrid + SOR (Gauss–Seidel with over-relaxation) on the
// 4-connected grid.
//
// CPU only: lexicographic SOR is order-dependent (each update reads the ones before it), so a
// parallel red–black Metal solve would converge to the same membrane by a different path and land
// within the reference's own tolerance (2e-3) rather than on its numbers; healing dabs are small
// (a 300 px dab solves in a few milliseconds).

/// Poisson solvers on `w × h` grids (photocraft `poisson`).
public enum Poisson {
    /// Convergence threshold (max per-sweep update) for the SOR sweeps.
    static let tol: Float = 2e-5
    /// SOR sweeps (cap) and relaxation on every level above the coarsest.
    static let fineIters = 30
    static let fineOmega: Float = 1.7

    /// Solves `Δv = 0` on `unknown` pixels with Dirichlet values from the known pixels of `v`
    /// (out-of-grid neighbours ignored: a Neumann boundary). Cascadic multigrid + SOR.
    public static func solveMembrane(width w: Int, height h: Int, unknown: [Bool], values v: inout [Float]) {
        precondition(unknown.count == w * h && v.count == w * h)
        solveRec(w, h, unknown, &v, 0)
    }

    static func solveRec(_ w: Int, _ h: Int, _ unknown: [Bool], _ v: inout [Float], _ depth: Int) {
        let nUnknown = unknown.reduce(0) { $0 + ($1 ? 1 : 0) }
        if nUnknown == 0 { return }
        var known: [Float] = []
        for i in 0..<v.count where !unknown[i] { known.append(v[i]) }
        if known.isEmpty { return }
        if w >= 8 && h >= 8 && nUnknown > 64 && depth < 16 {
            // Restrict: a coarse pixel is known if any of its children is (value = mean of known children).
            let cw = (w + 1) / 2, chh = (h + 1) / 2
            var cu = [Bool](repeating: true, count: cw * chh)
            var cv = [Float](repeating: 0, count: cw * chh)
            for cy in 0..<chh {
                for cx in 0..<cw {
                    var s: Float = 0, n: UInt32 = 0
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let x = cx * 2 + dx, y = cy * 2 + dy
                        if x < w && y < h && !unknown[y * w + x] { s += v[y * w + x]; n += 1 }
                    }
                    if n > 0 { cu[cy * cw + cx] = false; cv[cy * cw + cx] = s / Float(n) }
                }
            }
            solveRec(cw, chh, cu, &cv, depth + 1)
            // Prolong: bilinear sample of the coarse solution as the initial guess.
            for y in 0..<h {
                let fy = clampf((Float(y) + 0.5) / 2 - 0.5, 0, Float(chh - 1))
                let y0 = Int(fy.rounded(.down)), y1 = min(y0 + 1, chh - 1)
                let ty = fy - Float(y0)
                for x in 0..<w where unknown[y * w + x] {
                    let fx = clampf((Float(x) + 0.5) / 2 - 0.5, 0, Float(cw - 1))
                    let x0 = Int(fx.rounded(.down)), x1 = min(x0 + 1, cw - 1)
                    let tx = fx - Float(x0)
                    let a = cv[y0 * cw + x0] + (cv[y0 * cw + x1] - cv[y0 * cw + x0]) * tx
                    let b = cv[y1 * cw + x0] + (cv[y1 * cw + x1] - cv[y1 * cw + x0]) * tx
                    v[y * w + x] = a + (b - a) * ty
                }
            }
            sor(w, h, unknown, &v, fineIters, fineOmega)
        } else {
            var mean: Float = 0
            for k in known { mean += k }
            mean /= Float(known.count)
            for i in 0..<v.count where unknown[i] { v[i] = mean }
            sor(w, h, unknown, &v, 2000, 1.85)
        }
    }

    /// SOR sweeps over the unknown pixels until the largest update drops below `tol`.
    static func sor(_ w: Int, _ h: Int, _ unknown: [Bool], _ v: inout [Float], _ maxIter: Int, _ omega: Float) {
        var cells: [(Int, UInt8)] = []
        for i in 0..<(w * h) where unknown[i] {
            let x = i % w, y = i / w
            let m: UInt8 = (x > 0 ? 1 : 0) | (x + 1 < w ? 2 : 0) | (y > 0 ? 4 : 0) | (y + 1 < h ? 8 : 0)
            cells.append((i, m))
        }
        v.withUnsafeMutableBufferPointer { v in
            for _ in 0..<maxIter {
                var maxD: Float = 0
                for (i, m) in cells {
                    var s: Float, n: Float
                    if m == 0b1111 {
                        s = v[i - 1] + v[i + 1] + v[i - w] + v[i + w]; n = 4
                    } else {
                        s = 0; n = 0
                        if m & 1 != 0 { s += v[i - 1]; n += 1 }
                        if m & 2 != 0 { s += v[i + 1]; n += 1 }
                        if m & 4 != 0 { s += v[i - w]; n += 1 }
                        if m & 8 != 0 { s += v[i + w]; n += 1 }
                        if n == 0 { continue }
                    }
                    let d = omega * (s / n - v[i])
                    v[i] += d
                    maxD = Float.maximum(maxD, abs(d))
                }
                if maxD < tol { break }
            }
        }
    }

    /// Reference solver for tests: plain Gauss–Seidel from a zero start until the update is below `tol`.
    static func solveMembraneReference(_ w: Int, _ h: Int, _ unknown: [Bool], _ v: inout [Float], _ tol: Float, _ maxIter: Int) {
        for i in 0..<v.count where unknown[i] { v[i] = 0 }
        for _ in 0..<maxIter {
            var maxD: Float = 0
            for y in 0..<h {
                for x in 0..<w where unknown[y * w + x] {
                    var s: Float = 0, n: Float = 0
                    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                        s += v[ny * w + nx]; n += 1
                    }
                    if n > 0 {
                        let nv = s / n
                        maxD = max(maxD, abs(nv - v[y * w + x]))
                        v[y * w + x] = nv
                    }
                }
            }
            if maxD < tol { break }
        }
    }

    /// `f(c)` for each channel as a planar slice, in parallel, interleaved back.
    static func perChannel(_ w: Int, _ h: Int, _ ch: Int, _ f: (Int) -> [Float]) -> [Float] {
        var planes = [[Float]](repeating: [], count: ch)
        planes.withUnsafeMutableBufferPointer { pb in
            let ps = UnsafeSendable(pb)
            parallelFor(ch) { c in ps.value[c] = f(c) }
        }
        var out = [Float](repeating: 0, count: w * h * ch)
        for (c, p) in planes.enumerated() { for i in 0..<p.count { out[i * ch + c] = p[i] } }
        return out
    }

    /// Seamless cloning (guidance field ∇src): `dst` outside `mask`; inside, `src` plus the membrane
    /// that removes the boundary mismatch (source texture, destination colour and lighting).
    public static func seamlessClone(width w: Int, height h: Int, channels ch: Int, source src: [Float], destination dst: [Float],
                                     mask: [Bool]) -> [Float] {
        precondition(src.count == w * h * ch && dst.count == w * h * ch && mask.count == w * h)
        return perChannel(w, h, ch) { c in
            var hv = (0..<(w * h)).map { mask[$0] ? 0 : dst[$0 * ch + c] - src[$0 * ch + c] }
            solveMembrane(width: w, height: h, unknown: mask, values: &hv)
            return (0..<(w * h)).map { mask[$0] ? src[$0 * ch + c] + hv[$0] : dst[$0 * ch + c] }
        }
    }

    /// Membrane fill (no source texture): harmonic interpolation of the known pixels into `hole`.
    public static func membraneFill(width w: Int, height h: Int, channels ch: Int, image img: [Float], hole: [Bool]) -> [Float] {
        perChannel(w, h, ch) { c in
            var v = (0..<(w * h)).map { hole[$0] ? 0 : img[$0 * ch + c] }
            solveMembrane(width: w, height: h, unknown: hole, values: &v)
            return v
        }
    }
}
