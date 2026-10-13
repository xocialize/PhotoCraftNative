// Port of photocraft-algo (crates/algo/src/selection_blur.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The mask blurs behind Select › Modify › Smooth and Feather, both separable and confined to the
// mask's non-zero bounding box grown by the kernel radius:
//
// * Smooth: box average with edge-replicated borders (Double running sums), then a hard
//   threshold at ½.
// * Feather: a Gaussian with σ = radius, truncated at ⌈3σ⌉ and normalised, zero outside the
//   canvas. Kernels up to radius 12 are convolved directly (Float); wider ones are written as a
//   least-squares cosine series over the window, `k(j) ≈ a₀ + Σ aₖ cos(ωₖ j)`, each term a sliding
//   windowed sum updated in O(1) per pixel (Double), checked to ≤ 0.3/255 per pass, else direct.
//
// The CPU port reproduces photocraft's arithmetic (the spec is its numbers). The Metal paths
// (Shaders/SelectionBlur.metal): Smooth runs Float running sums (identical except where the box
// average sits within ~1e-6 of ½, where the threshold may flip); Feather convolves the exact
// truncated Gaussian directly (bit-identical up to radius 12, within the cosine fit's error —
// ≤ 0.6/255 — above).

import Foundation
import PCFoundation

extension Selection {
    /// Select › Modify › Smooth: box average of radius `round(r)` (edges replicated), then a hard
    /// threshold at ½: straight edges stay, corners round off, specks drop.
    public static func smooth(_ m: [Float], w: Int, h: Int, r: Float, on backend: Backend = .auto) throws -> [Float] {
        let curve = { (v: Float) -> Float in v >= 0.5 ? 1 : 0 }
        let (n, ovf) = w.multipliedReportingOverflow(by: h)
        if ovf || m.count != n || n == 0 { return m.map(curve) }
        let rr: Int = r.isFinite ? min(SelectionKit.usizeCast(Float.maximum(r, 0).rounded()), SelectionKit.Blur.maxBoxR) : (r > 0 ? SelectionKit.Blur.maxBoxR : 0)
        guard let b = SelectionKit.Blur.nonzeroBounds(m, w, h) else { return [Float](repeating: curve(0), count: n) }
        // Grown one past the radius, so a window edge inside the canvas sits on zeros and edge
        // replication there equals the zeros beyond it.
        let win = SelectionKit.Blur.grow(b, rr &+ 1, w, h)
        if try useGPU(backend, n), rr <= SelectionKit.Blur.gpuMaxBoxR {
            let res = try SelectionKit.GPU.smoothWindow(m, w: w, b: b, win: win, r: rr)
            return SelectionKit.Blur.assembleWindow(res, win, w, h, curve(0), curve)
        }
        let gw = win.w
        var tmp = [Float](repeating: 0, count: b.h * gw)
        tmp.withUnsafeMutableBufferPointer { tb in
            let t = UnsafeSendable(tb)
            m.withUnsafeBufferPointer { mb in
                parallelChunks(b.h, minChunk: 4) { rows in
                    for y in rows {
                        let o = (b.y0 + y) * w + win.x0
                        SelectionKit.Blur.boxLine(UnsafeBufferPointer(rebasing: mb[o..<(o + gw)]),
                                         UnsafeMutableBufferPointer(rebasing: t.value[(y * gw)..<(y * gw + gw)]), rr)
                    }
                }
            }
        }
        let res = tmp.withUnsafeBufferPointer { tb in
            let rows = SelectionKit.Blur.Rows(tmp: tb, gw: gw, bh: b.h, off: b.y0 - win.y0, gh: win.h)
            return SelectionKit.Blur.strips(gw) { c0, sw in SelectionKit.Blur.boxStrip(rows, c0, sw, rr) }
        }
        return SelectionKit.Blur.assemble(res, win, w, h, curve(0), curve)
    }

    /// Select › Modify › Feather: Gaussian blur of the mask with `σ = radius` (Photoshop's feather
    /// radius is the Gaussian's σ), kernel truncated at ⌈3σ⌉ and normalised, zero beyond the canvas.
    public static func feather(_ m: [Float], w: Int, h: Int, radius: Float, on backend: Backend = .auto) throws -> [Float] {
        let (n, ovf) = w.multipliedReportingOverflow(by: h)
        var sigma: Float = radius.isFinite ? Float.maximum(radius, 0) : (radius > 0 ? SelectionKit.Blur.maxSigma : 0)
        if sigma < 0.1 || ovf || m.count != n || n == 0 { return m }
        sigma = Float.minimum(sigma, SelectionKit.Blur.maxSigma)
        let r = SelectionKit.usizeCast((sigma * 3).rounded(.up))
        guard let b = SelectionKit.Blur.nonzeroBounds(m, w, h) else { return m }
        let win = SelectionKit.Blur.grow(b, r, w, h)
        let gw = win.w, gh = win.h
        let s = Double(sigma)
        let kh = SelectionKit.Blur.Kernel(sigma: s, r: r, n: gw), kv = SelectionKit.Blur.Kernel(sigma: s, r: r, n: gh)
        let cleanup = { (v: Float) -> Float in abs(v) < 1e-7 ? 0 : v }
        if try useGPU(backend, n) {
            let res = try SelectionKit.GPU.featherWindow(m, w: w, b: b, win: win, taps: (kh.directTaps(sigma: s, r: r), kv.directTaps(sigma: s, r: r)))
            return SelectionKit.Blur.assembleWindow(res, win, w, h, 0, cleanup)
        }
        // Rows: only the bounding box's rows are non-zero.
        var tmp = [Float](repeating: 0, count: b.h * gw)
        tmp.withUnsafeMutableBufferPointer { tb in
            let t = UnsafeSendable(tb)
            m.withUnsafeBufferPointer { mb in
                parallelChunks(b.h, minChunk: 2) { rows in
                    var runs: [Int] = []
                    for y in rows {
                        let o = (b.y0 + y) * w + win.x0
                        kh.line(UnsafeBufferPointer(rebasing: mb[o..<(o + gw)]), UnsafeMutableBufferPointer(rebasing: t.value[(y * gw)..<(y * gw + gw)]), &runs)
                    }
                }
            }
        }
        let res = tmp.withUnsafeBufferPointer { tb in
            let rows = SelectionKit.Blur.Rows(tmp: tb, gw: gw, bh: b.h, off: b.y0 - win.y0, gh: gh)
            return SelectionKit.Blur.strips(gw) { c0, sw in kv.strip(rows, c0, sw) }
        }
        // Rounding residue of the sliding sums is not coverage.
        return SelectionKit.Blur.assemble(res, win, w, h, 0, cleanup)
    }
}

/// photocraft `selection_blur` internals.
extension SelectionKit { enum Blur {
    /// Cosine terms in the wide-kernel series.
    static let terms = 5
    /// Kernels up to this radius are convolved directly.
    static let directMaxR = 12
    /// Largest error (mask units, per pass) a cosine fit may have before falling back.
    static let fitTol: Double = 0.3 / 255
    /// σ cap (keeps the kernel arithmetic finite for absurd radii).
    static let maxSigma: Float = 100_000
    /// Box radius cap.
    static let maxBoxR = 1 << 24
    /// Columns per task in the vertical pass.
    static let strip = 64
    /// The Metal Smooth handles radii up to this (Float window sums); larger run on the CPU.
    static let gpuMaxBoxR = 1 << 20

    /// A window of the mask: columns x0..<x1, rows y0..<y1.
    struct Win: Sendable, Equatable {
        var x0: Int, x1: Int, y0: Int, y1: Int
        var w: Int { x1 - x0 }
        var h: Int { y1 - y0 }
    }

    /// Bounding box of the non-zero samples (NaN counts as non-zero), nil when all are 0.
    static func nonzeroBounds(_ m: [Float], _ w: Int, _ h: Int) -> Win? {
        var rows = [(Int, Int)?](repeating: nil, count: h)
        rows.withUnsafeMutableBufferPointer { rb in
            let r = UnsafeSendable(rb)
            m.withUnsafeBufferPointer { mb in
                parallelChunks(h, minChunk: 16) { range in
                    for y in range {
                        let row = UnsafeBufferPointer(rebasing: mb[(y * w)..<(y * w + w)])
                        guard let first = row.firstIndex(where: { $0 != 0 }), let last = row.lastIndex(where: { $0 != 0 }) else { continue }
                        r.value[y] = (first, last + 1)
                    }
                }
            }
        }
        var b: Win?
        for (y, r) in rows.enumerated() {
            guard let (a, z) = r.map({ ($0.0, $0.1) }) else { continue }
            if let bb = b { b = Win(x0: min(bb.x0, a), x1: max(bb.x1, z), y0: bb.y0, y1: y + 1) } else { b = Win(x0: a, x1: z, y0: y, y1: y + 1) }
        }
        return b
    }

    /// `b` grown by `g` on every side, clamped to w × h.
    static func grow(_ b: Win, _ g: Int, _ w: Int, _ h: Int) -> Win {
        Win(x0: b.x0 > g ? b.x0 - g : 0, x1: min(b.x1 &+ g < b.x1 ? Int.max : b.x1 + g, w),
            y0: b.y0 > g ? b.y0 - g : 0, y1: min(b.y1 &+ g < b.y1 ? Int.max : b.y1 + g, h))
    }

    /// The horizontal pass's output as the vertical pass reads it: `bh` rows of `gw` samples at
    /// window rows `off..<off + bh` of a window `gh` rows tall (other rows are zero).
    struct Rows: @unchecked Sendable {
        let tmp: UnsafeBufferPointer<Float>
        let gw: Int, bh: Int, off: Int, gh: Int

        @inline(__always)
        func get(_ yy: Int, _ c0: Int, _ sw: Int) -> UnsafeBufferPointer<Float>? {
            let r = yy - off
            if r < 0 || r >= bh { return nil }
            return UnsafeBufferPointer(rebasing: tmp[(r * gw + c0)..<(r * gw + c0 + sw)])
        }
    }

    /// The vertical pass `f(c0, sw)` on strips of `strip` columns in parallel; each returns its
    /// gh × sw result, row-major.
    static func strips(_ gw: Int, _ f: (Int, Int) -> [Float]) -> [[Float]] {
        let count = (gw + strip - 1) / strip
        var out = [[Float]](repeating: [], count: count)
        out.withUnsafeMutableBufferPointer { ob in
            let o = UnsafeSendable(ob)
            parallelFor(count) { s in
                let c0 = s * strip
                o.value[s] = f(c0, min(strip, gw - c0))
            }
        }
        return out
    }

    /// Writes the strips into a fresh w × h mask through `f`; outside the window it is `outside`.
    static func assemble(_ strips: [[Float]], _ win: Win, _ w: Int, _ h: Int, _ outside: Float, _ f: (Float) -> Float) -> [Float] {
        var out = [Float](repeating: outside, count: w * h)
        out.withUnsafeMutableBufferPointer { ob in
            let o = UnsafeSendable(ob)
            parallelChunks(win.h, minChunk: 8) { rows in
                for yy in rows {
                    let y = win.y0 + yy
                    for (s, st) in strips.enumerated() {
                        let c0 = s * strip
                        let sw = min(strip, max(win.w - c0, 0))
                        for i in 0..<sw { o.value[y * w + win.x0 + c0 + i] = f(st[yy * sw + i]) }
                    }
                }
            }
        }
        return out
    }

    /// `assemble` for a window computed in one piece (gw × gh, row-major; the Metal paths).
    static func assembleWindow(_ res: [Float], _ win: Win, _ w: Int, _ h: Int, _ outside: Float, _ f: (Float) -> Float) -> [Float] {
        var out = [Float](repeating: outside, count: w * h)
        out.withUnsafeMutableBufferPointer { ob in
            let o = UnsafeSendable(ob)
            parallelChunks(win.h, minChunk: 8) { rows in
                for yy in rows {
                    for x in 0..<win.w { o.value[(win.y0 + yy) * w + win.x0 + x] = f(res[yy * win.w + x]) }
                }
            }
        }
        return out
    }

    /// Adds `k ×` window row `yy` (columns c0..<c0 + acc.count) into `acc`.
    @inline(__always)
    static func addRow(_ acc: inout [Double], _ rows: Rows, _ yy: Int, _ c0: Int, _ k: Double) {
        if k == 0 { return }
        guard let row = rows.get(yy, c0, acc.count) else { return }
        for i in 0..<acc.count { acc[i] += k * Double(row[i]) }
    }

    // MARK: Smooth

    /// Running-sum box average of one line (radius `r`, edges replicated) — photocraft `box_line`.
    static func boxLine(_ src: UnsafeBufferPointer<Float>, _ dst: UnsafeMutableBufferPointer<Float>, _ r: Int) {
        let n = min(src.count, dst.count)
        if n == 0 { return }
        let first = src[0], last = src[n - 1]
        if r == 0 {
            for i in 0..<n { dst[i] = src[i] }
            return
        }
        @inline(__always) func at(_ i: Int) -> Double { Double(src[min(max(i, 0), n - 1)]) }
        // Window at x = 0: r copies of the first sample, src[0...r], then copies of the last.
        let inside = min(r, n - 1)
        var s = 0.0
        for i in 0...inside { s += Double(src[i]) }
        var acc = Double(r) * Double(first) + s + Double(r - inside) * Double(last)
        let norm = 1 / Double(2 * r + 1)
        for x in 0..<n {
            dst[x] = Float(acc * norm)
            acc += at(x + r + 1) - at(x - r)
        }
    }

    /// The vertical box pass over columns c0..<c0 + sw (edges replicated) — photocraft `box_strip`.
    static func boxStrip(_ rows: Rows, _ c0: Int, _ sw: Int, _ r: Int) -> [Float] {
        let gh = rows.gh
        var out = [Float](repeating: 0, count: gh * sw)
        if gh == 0 || sw == 0 { return out }
        var acc = [Double](repeating: 0, count: sw)
        // Window at row 0: r copies of row 0, rows 0...r, then copies of the last row.
        let inside = min(r, gh - 1)
        addRow(&acc, rows, 0, c0, Double(r))
        for j in 0...inside { addRow(&acc, rows, j, c0, 1) }
        addRow(&acc, rows, gh - 1, c0, Double(r - inside))
        let norm = 1 / Double(2 * r + 1)
        for yy in 0..<gh {
            for i in 0..<sw { out[yy * sw + i] = Float(acc[i] * norm) }
            addRow(&acc, rows, min(yy + r + 1, gh - 1), c0, 1)
            addRow(&acc, rows, yy > r ? yy - r : 0, c0, -1)
        }
        return out
    }

    // MARK: Feather

    /// Solves the small dense system a·x = b with partial pivoting (photocraft `solve`; ties in
    /// the pivot search go to the last row, as Rust's `max_by`); nil when singular.
    static func solve(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        let n = b.count
        for c in 0..<n {
            var p = c
            for i in c..<n where abs(a[i][c]) >= abs(a[p][c]) { p = i }
            if abs(a[p][c]) < 1e-12 { return nil }
            a.swapAt(c, p)
            b.swapAt(c, p)
            for i in (c + 1)..<max(n, c + 1) {
                let f = a[i][c] / a[c][c]
                for j in c..<n { a[i][j] -= f * a[c][j] }
                b[i] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = 0.0
            for j in (i + 1)..<max(n, i + 1) { s += a[i][j] * x[j] }
            x[i] = (b[i] - s) / a[i][i]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// Sliding cosine-series form of a symmetric kernel over -r...r.
    struct CosKernel: Sendable {
        var r: Int
        var a0: Double
        var a: [Double]
        /// e^{-iω}: shifts the window by one sample.
        var rot: [(Double, Double)]
        /// e^{-iωr} (leaving sample) and e^{iωr} (entering sample).
        var outW: [(Double, Double)]
        var inW: [(Double, Double)]
        /// Σ_{|j|≤r} cos(ωj): a window full of ones.
        var full: [Double]
        var omega: [Double]
    }

    /// The feather kernel along lines of one length: direct taps or the cosine series.
    enum Kernel: Sendable {
        case direct([Float])
        case cos(CosKernel)

        /// photocraft `Kernel::new` (σ, truncation radius `r`, lines of length `n`).
        init(sigma: Double, r: Int, n: Int) {
            func g(_ j: Double) -> Double { exp(-(j * j) / (2 * sigma * sigma)) }
            var s = 0.0
            if r >= 1 { for j in 1...r { s += g(Double(j)) } }
            let total = 1 + 2 * s
            let jr = min(r, n > 0 ? n - 1 : 0)
            if jr == 0 {
                self = .direct([Float(1 / total)])
                return
            }
            let taps = (0...jr).map { g(Double($0)) / total }
            let direct = Kernel.direct((0...(2 * jr)).map { Float(taps[abs($0 - jr)]) })
            if jr <= SelectionKit.Blur.directMaxR {
                self = direct
                return
            }
            let T = SelectionKit.Blur.terms
            let l = Double(jr + 1)
            let omega = (0..<T).map { Double.pi * Double($0 + 1) / l }
            func basis(_ q: Int, _ j: Int) -> Double { q == 0 ? 1 : Foundation.cos(omega[q - 1] * Double(j)) }
            func wt(_ j: Int) -> Double { j == 0 ? 1 : 2 }
            var a = [[Double]](repeating: [Double](repeating: 0, count: T + 1), count: T + 1)
            var b = [Double](repeating: 0, count: T + 1)
            var phi = [Double](repeating: 0, count: T + 1)
            for (j, t) in taps.enumerated() {
                for q in 0...T { phi[q] = basis(q, j) }
                for p in 0...T {
                    b[p] += wt(j) * phi[p] * t
                    for q in 0...T { a[p][q] += wt(j) * phi[p] * phi[q] }
                }
            }
            guard let c = SelectionKit.Blur.solve(a, b) else {
                self = direct
                return
            }
            // Error bound per pass: half the L1 distance between the series and the kernel.
            var err = 0.0
            for (j, t) in taps.enumerated() {
                var v = 0.0
                for q in 0...T { v += c[q] * basis(q, j) }
                err += wt(j) * abs(v - t)
            }
            err /= 2
            if !err.isFinite || err > SelectionKit.Blur.fitTol {
                self = direct
                return
            }
            let jf = Double(jr)
            let full = (0..<T).map { k -> Double in
                var s = 0.0
                for j in 1...jr { s += Foundation.cos(omega[k] * Double(j)) }
                return 1 + 2 * s
            }
            self = .cos(CosKernel(r: jr, a0: c[0], a: Array(c[1...]),
                                  rot: omega.map { (Foundation.cos($0), -Foundation.sin($0)) },
                                  outW: omega.map { (Foundation.cos($0 * jf), -Foundation.sin($0 * jf)) },
                                  inW: omega.map { (Foundation.cos($0 * jf), Foundation.sin($0 * jf)) },
                                  full: full, omega: omega))
        }

        /// The Float taps of the direct truncated Gaussian for this kernel's line length (the
        /// Metal path's kernel, whatever form the CPU uses).
        func directTaps(sigma: Double, r: Int) -> [Float] {
            switch self {
            case .direct(let t): return t
            case .cos(let k):
                func g(_ j: Double) -> Double { exp(-(j * j) / (2 * sigma * sigma)) }
                var s = 0.0
                if r >= 1 { for j in 1...r { s += g(Double(j)) } }
                let total = 1 + 2 * s
                let taps = (0...k.r).map { g(Double($0)) / total }
                return (0...(2 * k.r)).map { Float(taps[abs($0 - k.r)]) }
            }
        }

        /// Convolves one line (zero outside it) into `dst`.
        func line(_ src: UnsafeBufferPointer<Float>, _ dst: UnsafeMutableBufferPointer<Float>, _ runs: inout [Int]) {
            let n = min(src.count, dst.count)
            switch self {
            case .direct(let taps):
                let r = taps.count / 2
                for i in 0..<n { dst[i] = 0 }
                for (i, k) in taps.enumerated() {
                    // Output x reads src[x + i - r].
                    let (d0, s0) = i >= r ? (0, i - r) : (r - i, 0)
                    if d0 >= n || s0 >= n { continue }
                    let len = min(n - d0, n - s0)
                    for t in 0..<len { dst[d0 + t] += k * src[s0 + t] }
                }
            case .cos(let k):
                SelectionKit.Blur.cosLine(k, UnsafeBufferPointer(rebasing: src[0..<n]), dst, &runs)
            }
        }

        /// The vertical pass over columns c0..<c0 + sw (zero outside the window).
        func strip(_ rows: Rows, _ c0: Int, _ sw: Int) -> [Float] {
            switch self {
            case .direct(let taps):
                let r = taps.count / 2
                var out = [Float](repeating: 0, count: rows.gh * sw)
                if sw == 0 { return out }
                for yy in 0..<rows.gh {
                    for (i, k) in taps.enumerated() {
                        let y = yy + i - r
                        if y < 0 { continue }
                        guard let src = rows.get(y, c0, sw) else { continue }
                        for t in 0..<sw { out[yy * sw + t] += k * src[t] }
                    }
                }
                return out
            case .cos(let k):
                return SelectionKit.Blur.cosStrip(k, rows, c0, sw)
            }
        }
    }

    /// photocraft `CosKernel::line`.
    static func cosLine(_ k: CosKernel, _ src: UnsafeBufferPointer<Float>, _ dst: UnsafeMutableBufferPointer<Float>, _ runs: inout [Int]) {
        let n = src.count, r = k.r, T = terms
        // runs[i]: end (exclusive) of the constant run containing i.
        runs.removeAll(keepingCapacity: true)
        runs.append(contentsOf: repeatElement(n, count: n))
        if n >= 2 {
            for i in stride(from: n - 2, through: 0, by: -1) { runs[i] = src[i] == src[i + 1] ? runs[i + 1] : i + 1 }
        }
        @inline(__always) func at(_ i: Int) -> Double { i < n ? Double(src[i]) : 0 }
        var have = false
        var sb = 0.0
        var sr = [Double](repeating: 0, count: T), si = [Double](repeating: 0, count: T)
        for x in 0..<n {
            let lo = x > r ? x - r : 0
            let hi = min(x + r + 1, n)
            let c = src[lo]
            if runs[lo] >= hi && (c == 0 || (x >= r && x + r < n)) {
                // The whole window is one value (zeros may run off the line; ones may not).
                dst[x] = c
                let cf = Double(c)
                sb = cf * Double(2 * r + 1)
                for q in 0..<T { sr[q] = cf * k.full[q]; si[q] = 0 }
                have = true
                continue
            }
            if have {
                // Slide from x - 1: drop src[x - 1 - r], take src[x + r].
                let gone = x > r ? at(x - 1 - r) : 0
                let come = at(x + r)
                sb += come - gone
                for q in 0..<T {
                    let re = sr[q] - gone * k.outW[q].0, im = si[q] - gone * k.outW[q].1
                    let (cr, ci) = k.rot[q]
                    sr[q] = re * cr - im * ci + come * k.inW[q].0
                    si[q] = re * ci + im * cr + come * k.inW[q].1
                }
            } else {
                // Direct sums over the in-line part of the window.
                sb = 0
                for q in 0..<T { sr[q] = 0; si[q] = 0 }
                for i in lo..<hi {
                    let v = Double(src[i])
                    if v == 0 { continue }
                    let j = Double(i) - Double(x)
                    sb += v
                    for q in 0..<T {
                        sr[q] += v * Foundation.cos(k.omega[q] * j)
                        si[q] += v * Foundation.sin(k.omega[q] * j)
                    }
                }
                have = true
            }
            var s = 0.0
            for q in 0..<T { s += k.a[q] * sr[q] }
            dst[x] = Float(k.a0 * sb + s)
        }
    }

    /// photocraft `CosKernel::strip`: `cosLine` down columns c0..<c0 + sw, all columns of a row at once.
    static func cosStrip(_ k: CosKernel, _ rows: Rows, _ c0: Int, _ sw: Int) -> [Float] {
        let gh = rows.gh, r = k.r, T = terms
        var out = [Float](repeating: 0, count: gh * sw)
        if sw == 0 { return out }
        // Rows whose strip segment is one value, and the runs of equal such rows.
        let flag: [Float?] = (0..<gh).map { yy in
            guard let s = rows.get(yy, c0, sw) else { return 0 }
            let c = s[0]
            return s.allSatisfy { $0 == c } ? c : nil
        }
        var runs = [Int](repeating: gh, count: gh)
        if gh >= 2 {
            for i in stride(from: gh - 2, through: 0, by: -1) {
                if let a = flag[i], let b = flag[i + 1], a == b { runs[i] = runs[i + 1] } else { runs[i] = i + 1 }
            }
        }
        let zeros = [Float](repeating: 0, count: sw)
        var sb = [Double](repeating: 0, count: sw)
        var re = [[Double]](repeating: [Double](repeating: 0, count: sw), count: T)
        var im = re
        var acc = [Double](repeating: 0, count: sw)
        var have = false
        zeros.withUnsafeBufferPointer { zb in
            for yy in 0..<gh {
                let lo = yy > r ? yy - r : 0
                let hi = min(yy + r + 1, gh)
                // The whole window is one value (zero rows may run off the window; others may not).
                if let c = flag[lo], runs[lo] >= hi, c == 0 || (yy >= r && yy + r < gh) {
                    for i in 0..<sw { out[yy * sw + i] = c }
                    let cf = Double(c)
                    for i in 0..<sw { sb[i] = cf * Double(2 * r + 1) }
                    for q in 0..<T {
                        let v = cf * k.full[q]
                        for i in 0..<sw { re[q][i] = v; im[q][i] = 0 }
                    }
                    have = true
                    continue
                }
                if have {
                    // Slide from yy - 1: drop row yy - 1 - r, take row yy + r.
                    let gone = (yy > r ? rows.get(yy - 1 - r, c0, sw) : nil) ?? zb
                    let come = rows.get(yy + r, c0, sw) ?? zb
                    for i in 0..<sw { sb[i] += Double(come[i]) - Double(gone[i]) }
                    for q in 0..<T {
                        let (cr, ci) = k.rot[q], (o0, o1) = k.outW[q], (i0, i1) = k.inW[q]
                        for i in 0..<sw {
                            let g = Double(gone[i]), c = Double(come[i])
                            let a = re[q][i] - g * o0, b = im[q][i] - g * o1
                            re[q][i] = a * cr - b * ci + c * i0
                            im[q][i] = a * ci + b * cr + c * i1
                        }
                    }
                } else {
                    // Direct sums over the in-window rows.
                    for i in 0..<sw { sb[i] = 0 }
                    for q in 0..<T { for i in 0..<sw { re[q][i] = 0; im[q][i] = 0 } }
                    for i in lo..<hi {
                        guard let row = rows.get(i, c0, sw) else { continue }
                        let j = Double(i) - Double(yy)
                        addRow(&sb, rows, i, c0, 1)
                        for q in 0..<T {
                            let cs = Foundation.cos(k.omega[q] * j), sn = Foundation.sin(k.omega[q] * j)
                            for t in 0..<sw {
                                re[q][t] += Double(row[t]) * cs
                                im[q][t] += Double(row[t]) * sn
                            }
                        }
                    }
                    have = true
                }
                for i in 0..<sw { acc[i] = k.a0 * sb[i] }
                for q in 0..<T { for i in 0..<sw { acc[i] += k.a[q] * re[q][i] } }
                for i in 0..<sw { out[yy * sw + i] = Float(acc[i]) }
            }
        }
        return out
    }
}
}
