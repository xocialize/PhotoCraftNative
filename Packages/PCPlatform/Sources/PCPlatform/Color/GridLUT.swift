// Sampled colour lookup tables with tetrahedral interpolation.
// Replaces photocraft-cms (crates/cms/src/clut.rs) — the grid sampling photocraft uses for device
// links, gamut checks and the CMYK fallback converter. Here a grid is filled from one batched
// ColorSync conversion and evaluated per pixel without calling into ColorSync. Port of its API shape,
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation

/// A regular grid over 1, 3 or 4 inputs in 0…1 with `outputs` values per node. Node order: the
/// first input varies fastest (photocraft `Lut3d`'s memory order: red fastest).
public struct GridLUT: Sendable, Equatable {
    public let inputs: Int
    public let size: Int
    public let outputs: Int
    public var data: [Float]

    public init(inputs: Int, size: Int, outputs: Int, data: [Float]) {
        precondition([1, 3, 4].contains(inputs) && size >= 2, "GridLUT: 1, 3 or 4 inputs and size ≥ 2")
        precondition(data.count == Self.nodeCount(inputs: inputs, size: size) * outputs, "GridLUT: data size")
        self.inputs = inputs; self.size = size; self.outputs = outputs; self.data = data
    }

    public static func nodeCount(inputs: Int, size: Int) -> Int {
        (0..<inputs).reduce(1) { a, _ in a * size }
    }

    /// Every grid node's input values, interleaved, in node order.
    public static func nodes(inputs: Int, size: Int) -> [Float] {
        let n = nodeCount(inputs: inputs, size: size)
        var out = [Float](repeating: 0, count: n * inputs)
        let s = Float(size - 1)
        for i in 0..<n {
            var r = i
            for k in 0..<inputs {
                out[i * inputs + k] = Float(r % size) / s
                r /= size
            }
        }
        return out
    }

    /// Samples `f` (a batch function: interleaved inputs → interleaved outputs) on the grid.
    public static func sample(inputs: Int, size: Int, outputs: Int, _ f: ([Float], Int) -> [Float]) -> GridLUT {
        let pts = nodes(inputs: inputs, size: size)
        let n = nodeCount(inputs: inputs, size: size)
        return GridLUT(inputs: inputs, size: size, outputs: outputs, data: f(pts, n))
    }

    @inline(__always) private func loc(_ v: Float) -> (Int, Float) {
        let p = min(max(v.isFinite ? v : 0, 0), 1) * Float(size - 1)
        let i = min(Int(p), size - 2)
        return (i, p - Float(i))
    }

    /// Tetrahedral interpolation (3D; 4D linear on the last input between two tetrahedra; 1D
    /// linear) — photocraft's `Clut::eval`, which keeps neutral axes exact.
    public func eval(_ x: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: outputs)
        eval(x, into: &out)
        return out
    }

    public func eval(_ x: [Float], into out: inout [Float]) {
        switch inputs {
        case 1:
            let (i, f) = loc(x[0])
            for k in 0..<outputs { out[k] = data[i * outputs + k] * (1 - f) + data[(i + 1) * outputs + k] * f }
        case 3:
            tetra(x[0], x[1], x[2], base: 0, weight: 1, into: &out, accumulate: false)
        default:
            let (ki, kf) = loc(x[3])
            let plane = size * size * size
            tetra(x[0], x[1], x[2], base: ki * plane, weight: 1 - kf, into: &out, accumulate: false)
            tetra(x[0], x[1], x[2], base: (ki + 1) * plane, weight: kf, into: &out, accumulate: true)
        }
    }

    private func tetra(_ r: Float, _ g: Float, _ b: Float, base: Int, weight: Float, into out: inout [Float], accumulate: Bool) {
        let (ri, fr) = loc(r), (gi, fg) = loc(g), (bi, fb) = loc(b)
        let s = size, s2 = size * size
        let o = outputs
        let i000 = (base + ri + gi * s + bi * s2) * o
        let dr = o, dg = s * o, db = s2 * o
        // The tetrahedron containing the point, ordered by fractional size.
        let (a1, w1, a2, w2, w3): (Int, Float, Int, Float, Float)
        if fr >= fg {
            if fg >= fb { (a1, w1, a2, w2, w3) = (dr, fr, dr + dg, fg, fb) }          // r ≥ g ≥ b
            else if fr >= fb { (a1, w1, a2, w2, w3) = (dr, fr, dr + db, fb, fg) }    // r ≥ b > g
            else { (a1, w1, a2, w2, w3) = (db, fb, db + dr, fr, fg) }                // b > r ≥ g
        } else {
            if fb > fg { (a1, w1, a2, w2, w3) = (db, fb, db + dg, fg, fr) }          // b > g > r
            else if fb > fr { (a1, w1, a2, w2, w3) = (dg, fg, dg + db, fb, fr) }     // g ≥ b > r
            else { (a1, w1, a2, w2, w3) = (dg, fg, dg + dr, fr, fb) }                // g > r ≥ b
        }
        let i111 = i000 + dr + dg + db
        data.withUnsafeBufferPointer { d in
            for k in 0..<o {
                let c000 = d[i000 + k], c1 = d[i000 + a1 + k], c2 = d[i000 + a2 + k], c111 = d[i111 + k]
                let v = c000 + w1 * (c1 - c000) + w2 * (c2 - c1) + w3 * (c111 - c2)
                out[k] = accumulate ? out[k] + v * weight : v * weight
            }
        }
    }

    /// Trilinear interpolation of a 3-input grid (what GPU texture filtering computes; photocraft
    /// `Lut3d::sample`).
    public func trilinear(_ x: [Float]) -> [Float] {
        precondition(inputs == 3, "trilinear needs 3 inputs")
        let (ri, fr) = loc(x[0]), (gi, fg) = loc(x[1]), (bi, fb) = loc(x[2])
        let s = size, s2 = size * size, o = outputs
        func at(_ r: Int, _ g: Int, _ b: Int, _ k: Int) -> Float { data[((r + g * s + b * s2) * o) + k] }
        var out = [Float](repeating: 0, count: o)
        for k in 0..<o {
            let x00 = at(ri, gi, bi, k) + (at(ri + 1, gi, bi, k) - at(ri, gi, bi, k)) * fr
            let x10 = at(ri, gi + 1, bi, k) + (at(ri + 1, gi + 1, bi, k) - at(ri, gi + 1, bi, k)) * fr
            let x01 = at(ri, gi, bi + 1, k) + (at(ri + 1, gi, bi + 1, k) - at(ri, gi, bi + 1, k)) * fr
            let x11 = at(ri, gi + 1, bi + 1, k) + (at(ri + 1, gi + 1, bi + 1, k) - at(ri, gi + 1, bi + 1, k)) * fr
            let y0 = x00 + (x10 - x00) * fg, y1 = x01 + (x11 - x01) * fg
            out[k] = y0 + (y1 - y0) * fb
        }
        return out
    }
}
