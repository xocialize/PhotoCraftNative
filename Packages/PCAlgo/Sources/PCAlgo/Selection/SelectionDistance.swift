// Port of photocraft-algo (crates/algo/src/selection/distance.rs; selection.rs: expand, contract, border), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Binary Euclidean distance transform (nearest seeds along columns, then the lower envelope of
// squared-distance parabolas along rows; Felzenszwalb & Huttenlocher 2012) and the modifiers
// built on it. The result at each pixel is `Float(sqrt(Double(n)))` with `n` the exact integer
// squared distance to the nearest seed; the Metal path (Shaders/SelectionDistance.metal)
// computes the same `n` with exact integer envelope comparisons and a correctly rounded square
// root, so it matches bit for bit.

import Foundation
import PCFoundation

extension Selection {
    /// Distance of every pixel of a mask with no seed (photocraft `EMPTY_DISTANCE`).
    public static let emptyDistance: Float = 1e10
    static let noSeed = UInt32.max

    /// Euclidean distance to the nearest `true` pixel, row-major. Inconsistent or empty
    /// dimensions give an empty array; a mask without seeds gives `emptyDistance` everywhere.
    public static func edt(_ inside: [Bool], w: Int, h: Int, on backend: Backend = .auto) throws -> [Float] {
        let (n, ovf) = w.multipliedReportingOverflow(by: h)
        if ovf || n == 0 || n > Int.max / 4 || n != inside.count || w > Int(UInt32.max) || h > Int(UInt32.max) { return [] }
        var any = false, all = true
        for v in inside { if v { any = true } else { all = false }; if any && !all { break } }
        if !any { return [Float](repeating: emptyDistance, count: n) }
        if all { return [Float](repeating: 0, count: n) }
        if try useGPU(backend, n), SelectionKit.GPU.edtFits(w, h) { return try SelectionKit.GPU.edt(inside, w: w, h: h) }
        return edtCPU(inside, w: w, h: h)
    }

    static func edtCPU(_ inside: [Bool], w: Int, h: Int) -> [Float] {
        let n = w * h
        // Column-major nearest-seed distances along columns.
        var vertical = [UInt32](repeating: noSeed, count: n)
        vertical.withUnsafeMutableBufferPointer { vb in
            let v = UnsafeSendable(vb)
            inside.withUnsafeBufferPointer { ins in
                parallelChunks(w, minChunk: 16) { cols in
                    for x in cols {
                        let col = v.value.baseAddress! + x * h
                        var nearest = -1
                        for y in 0..<h {
                            if ins[y * w + x] { nearest = y }
                            if nearest >= 0 { col[y] = UInt32(y - nearest) }
                        }
                        nearest = -1
                        for y in stride(from: h - 1, through: 0, by: -1) {
                            if col[y] == 0 { nearest = y }
                            if nearest >= 0 { col[y] = min(col[y], UInt32(nearest - y)) }
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: n)
        out.withUnsafeMutableBufferPointer { ob in
            let o = UnsafeSendable(ob)
            vertical.withUnsafeBufferPointer { vb in
                parallelChunks(h, minChunk: 4) { rows in
                    var costs = [UInt32](repeating: 0, count: w)
                    var sites = [Int](repeating: 0, count: w)
                    var starts = [Double](repeating: 0, count: w)
                    for y in rows {
                        for x in 0..<w { costs[x] = vb[x * h + y] }
                        rowDistance(costs, UnsafeMutableBufferPointer(rebasing: o.value[(y * w)..<(y * w + w)]), &sites, &starts)
                    }
                }
            }
        }
        return out
    }

    /// Lower envelope of parabolas with integer vertical distances along one row (photocraft
    /// `row_distance`; Double boundaries keep half-pixel precision on huge rows).
    static func rowDistance(_ costs: [UInt32], _ out: UnsafeMutableBufferPointer<Float>, _ sites: inout [Int], _ starts: inout [Double]) {
        var count = 0
        for q in 0..<costs.count where costs[q] != noSeed {
            let dq = Double(costs[q])
            let fq = dq * dq
            var start = -Double.infinity
            while count > 0 {
                let p = sites[count - 1]
                let dp = Double(costs[p])
                // (q² − p²)/(2(q − p)) = (q + p)/2: no subtraction of large rounded squares.
                start = (fq - dp * dp) / (2 * Double(q - p)) + (Double(q) + Double(p)) * 0.5
                if start > starts[count - 1] { break }
                count -= 1
            }
            if count == 0 { start = -.infinity }
            sites[count] = q
            starts[count] = start
            count += 1
        }
        if count == 0 {
            for i in 0..<out.count { out[i] = emptyDistance }
            return
        }
        var k = 0
        for x in 0..<out.count {
            while k + 1 < count && starts[k + 1] < Double(x) { k += 1 }
            let site = sites[k]
            let v = Double(costs[site])
            let dx = Double(x) - Double(site)
            out[x] = Float((dx * dx + v * v).squareRoot())
        }
    }

    // MARK: Modifiers

    /// Select › Modify › Expand: grows the selection by `r` pixels (a pixel `d` from the nearest
    /// selected centre is covered `clamp(r + 1 − d, 0, 1)`; fractional radii give partial coverage).
    public static func expand(_ m: [Float], w: Int, h: Int, r: Float, on backend: Backend = .auto) throws -> [Float] {
        let d = try edt(m.map { $0 >= 0.5 }, w: w, h: h, on: backend)
        return zip(m, d).map { v, d in Float.maximum(v, clampf(r + 1 - d, 0, 1)) }
    }

    /// Select › Modify › Contract: shrinks the selection by `r` pixels (expand of the inverse).
    public static func contract(_ m: [Float], w: Int, h: Int, r: Float, on backend: Backend = .auto) throws -> [Float] {
        try expand(m.map { 1 - $0 }, w: w, h: h, r: r, on: backend).map { 1 - $0 }
    }

    /// Select › Modify › Border: a soft band `2r` wide centred on the selection edge, as in
    /// Photoshop: a pixel `D` (centre to centre) from the nearest pixel on the other side of the
    /// edge is selected `1 − (D − 1)/r`.
    public static func border(_ m: [Float], w: Int, h: Int, r: Float, on backend: Backend = .auto) throws -> [Float] {
        let inside = m.map { $0 >= 0.5 }
        let toInside = try edt(inside, w: w, h: h, on: backend), toOutside = try edt(inside.map { !$0 }, w: w, h: h, on: backend)
        if r <= 0 || toInside.count != m.count || toOutside.count != m.count { return [Float](repeating: 0, count: m.count) }
        return (0..<m.count).map { i in clampf(1 - ((inside[i] ? toOutside[i] : toInside[i]) - 1) / r, 0, 1) }
    }
}
