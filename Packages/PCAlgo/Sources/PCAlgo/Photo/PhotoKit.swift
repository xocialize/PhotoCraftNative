// Port of photocraft-algo (crates/algo/src/photo_util.rs, features.rs helpers), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Small helpers shared by the computational-photography ports (pyramid, features, direct,
// panorama, scancrop): the SplitMix64 generator, order-preserving parallel maps, Rust's
// saturating float → integer casts and `total_cmp` ordering, and the stable index sort Rust's
// `sort_by` performs. The dense least-squares pair (`Normal`, `solve_dense`) is the Tone area's
// `NormalEquations` (identical arithmetic); features.rs has its own `solve` (below).

import Foundation
import Metal
import PCFoundation

enum PhotoKit {
    // MARK: - Deterministic generator

    /// SplitMix64 (photocraft `photo_util::Rng`, `features::Rng`).
    struct Rng {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// `0..1` with 53 random bits (features.rs `unit`).
        mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }

        /// `next() % max(n, 1)`.
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(Swift.max(n, 1))) }
    }

    // MARK: - Parallel loops (photocraft `par_map`, `par_rows`)

    /// `f(i)` for `0..<n` in parallel, results in order.
    static func parMap<T>(_ n: Int, _ f: (Int) -> T) -> [T] {
        if n <= 0 { return [] }
        var out = [T?](repeating: nil, count: n)
        out.withUnsafeMutableBufferPointer { b in
            let p = UnsafeSendable(b.baseAddress!)
            parallelFor(n) { i in p.value[i] = f(i) }
        }
        return out.map { $0! }
    }

    /// `body(y)` for every row in parallel (rows grouped in chunks for cheap bodies).
    @inline(__always)
    static func parRows(_ h: Int, _ body: (Int) -> Void) {
        parallelChunks(h, minChunk: 4) { r in for y in r { body(y) } }
    }

    // MARK: - Rust casts and orderings

    /// Rust `f64 as usize` (saturating; NaN and negatives → 0).
    @inline(__always) static func usize(_ v: Double) -> Int {
        if !(v > 0) { return 0 }
        return v >= 9.2e18 ? Int.max : Int(v)
    }

    /// Rust `f32 as usize`.
    @inline(__always) static func usize(_ v: Float) -> Int { usize(Double(v)) }

    /// Rust `f64 as i64` (saturating, NaN → 0).
    @inline(__always) static func i64(_ v: Double) -> Int {
        if v.isNaN { return 0 }
        if v >= 9.2e18 { return Int.max }
        if v <= -9.2e18 { return Int.min }
        return Int(v)
    }

    /// Rust `f64 as i32` (saturating, NaN → 0).
    @inline(__always) static func i32(_ v: Double) -> Int32 {
        if v.isNaN { return 0 }
        if v >= 2_147_483_647 { return .max }
        if v <= -2_147_483_648 { return .min }
        return Int32(v)
    }

    /// Rust `a.total_cmp(&b) == Less`.
    @inline(__always) static func totalLess(_ a: Double, _ b: Double) -> Bool { !b.isTotallyOrdered(belowOrEqualTo: a) }
    @inline(__always) static func totalLess(_ a: Float, _ b: Float) -> Bool { !b.isTotallyOrdered(belowOrEqualTo: a) }

    /// Rust's stable `sort_by`: the permutation sorting `0..<n` by `less`, equal keys in index order.
    static func stableOrder(_ n: Int, _ less: (Int, Int) -> Bool) -> [Int] {
        var idx = Array(0..<n)
        idx.sort { a, b in less(a, b) || (!less(b, a) && a < b) }
        return idx
    }

    /// Rust `f32::clamp(0.0, 1.0)` (NaN stays NaN).
    @inline(__always) static func clamp01(_ v: Float) -> Float { v < 0 ? 0 : (v > 1 ? 1 : v) }

    /// Rust `f64::clamp` (NaN stays NaN).
    @inline(__always) static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? lo : (v > hi ? hi : v) }

    /// Rust `f32::clamp` (NaN stays NaN).
    @inline(__always) static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { v < lo ? lo : (v > hi ? hi : v) }

    /// Rust `f32::max` (NaN-ignoring).
    @inline(__always) static func fmax(_ a: Float, _ b: Float) -> Float { a.isNaN ? b : (b.isNaN ? a : (a > b ? a : b)) }
    @inline(__always) static func fmin(_ a: Float, _ b: Float) -> Float { a.isNaN ? b : (b.isNaN ? a : (a < b ? a : b)) }
    @inline(__always) static func dmax(_ a: Double, _ b: Double) -> Double { a.isNaN ? b : (b.isNaN ? a : (a > b ? a : b)) }
    @inline(__always) static func dmin(_ a: Double, _ b: Double) -> Double { a.isNaN ? b : (b.isNaN ? a : (a < b ? a : b)) }

    /// Rust `f64::to_radians` / `to_degrees`.
    @inline(__always) static func radians(_ deg: Double) -> Double { deg * (Double.pi / 180.0) }
    @inline(__always) static func degrees(_ rad: Double) -> Double { rad * (180.0 / Double.pi) }

    // MARK: - Dense solves (features.rs)

    /// Gaussian elimination with partial pivoting (features.rs `solve`: pivot threshold 1e-12, no
    /// finiteness check). nil when singular.
    static func solve(_ n: Int, _ a0: [Double], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        for c in 0..<n {
            // Rust `max_by(total_cmp)`: the last of equal maxima.
            var p = c
            var best = abs(a[c * n + c])
            var i = c + 1
            while i < n {
                let v = abs(a[i * n + c])
                if best.isTotallyOrdered(belowOrEqualTo: v) { p = i; best = v }
                i += 1
            }
            if abs(a[p * n + c]) < 1e-12 { return nil }
            if p != c {
                for k in 0..<n { a.swapAt(c * n + k, p * n + k) }
                b.swapAt(c, p)
            }
            var r = c + 1
            while r < n {
                let f = a[r * n + c] / a[c * n + c]
                for k in c..<n { a[r * n + k] -= f * a[c * n + k] }
                b[r] -= f * b[c]
                r += 1
            }
        }
        var x = [Double](repeating: 0, count: n)
        var r = n - 1
        while r >= 0 {
            var s = -0.0
            var k = r + 1
            while k < n { s += a[r * n + k] * x[k]; k += 1 }
            x[r] = (b[r] - s) / a[r * n + r]
            r -= 1
        }
        return x
    }

    /// Least squares `min |A x − b|` through the normal equations (features.rs `least_squares`).
    static func leastSquares(_ rows: [([Double], Double)], _ n: Int) -> [Double]? {
        var ata = [Double](repeating: 0, count: n * n)
        var atb = [Double](repeating: 0, count: n)
        for (r, b) in rows {
            for i in 0..<n {
                atb[i] += r[i] * b
                for j in 0..<n { ata[i * n + j] += r[i] * r[j] }
            }
        }
        return solve(n, ata, atb)
    }

    /// Two-pass running-sum box blur of a plane, edge-clamped (features.rs `blur`, pyramid.rs
    /// `box_blur1`): horizontal then vertical, each output `acc / (2r + 1)` with `acc` updated by
    /// `+ at(k + r + 1) − at(k − r)`.
    static func boxBlur(_ w: Int, _ h: Int, _ v: [Float], _ r: Int) -> [Float] {
        func pass(_ src: [Float], _ horizontal: Bool) -> [Float] {
            var dst = [Float](repeating: 0, count: src.count)
            let (n, m) = horizontal ? (h, w) : (w, h)
            if m == 0 { return dst }
            let div = Float(2 * r + 1)
            src.withUnsafeBufferPointer { s in
                dst.withUnsafeMutableBufferPointer { d in
                    let dp = UnsafeSendable(d.baseAddress!)
                    let sp = UnsafeSendable(s.baseAddress!)
                    parallelChunks(n, minChunk: 8) { lines in
                        let s = sp.value, d = dp.value
                        for line in lines {
                            @inline(__always) func at(_ k: Int) -> Float {
                                let k = Swift.min(Swift.max(k, 0), m - 1)
                                return horizontal ? s[line * w + k] : s[k * w + line]
                            }
                            var acc: Float = -0.0
                            for k in -r...r { acc += at(k) }
                            for k in 0..<m {
                                let i = horizontal ? line * w + k : k * w + line
                                d[i] = acc / div
                                acc += at(k + r + 1) - at(k - r)
                            }
                        }
                    }
                }
            }
            return dst
        }
        return pass(pass(v, true), false)
    }

    // MARK: - GPU buffers

    /// A shared buffer holding `values`.
    static func sharedBuffer(_ gpu: AlgoGPU, _ values: [Float]) throws -> any MTLBuffer {
        let len = Swift.max(values.count * 4, 16)
        let b: (any MTLBuffer)? = values.isEmpty ? gpu.device.makeBuffer(length: len, options: .storageModeShared)
            : values.withUnsafeBytes { gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        guard let b else { throw FilterError.gpuUnavailable("makeBuffer \(len)") }
        return b
    }

    /// A shared buffer of `count` floats (contents undefined).
    static func sharedBuffer(_ gpu: AlgoGPU, count: Int) throws -> any MTLBuffer {
        guard let b = gpu.device.makeBuffer(length: Swift.max(count * 4, 16), options: .storageModeShared) else {
            throw FilterError.gpuUnavailable("makeBuffer \(count * 4)")
        }
        return b
    }

    /// A private buffer of `count` floats (contents undefined).
    static func privateBuffer(_ gpu: AlgoGPU, count: Int) throws -> any MTLBuffer {
        guard let b = gpu.device.makeBuffer(length: Swift.max(count * 4, 16), options: .storageModePrivate) else {
            throw FilterError.gpuUnavailable("makeBuffer \(count * 4)")
        }
        return b
    }

    /// The floats of a shared buffer.
    static func read(_ b: any MTLBuffer, count: Int) -> [Float] {
        if count == 0 { return [] }
        return [Float](unsafeUninitializedCapacity: count) { d, n in
            d.baseAddress!.update(from: b.contents().assumingMemoryBound(to: Float.self), count: count)
            n = count
        }
    }

    /// Copies `count` floats between buffers (blit).
    static func copy(_ cb: any MTLCommandBuffer, _ from: any MTLBuffer, _ fromOffset: Int = 0, to: any MTLBuffer, _ toOffset: Int = 0,
                     count: Int) throws {
        if count <= 0 { return }
        guard let b = cb.makeBlitCommandEncoder() else { throw FilterError.gpuUnavailable("blit") }
        b.copy(from: from, sourceOffset: fromOffset * 4, to: to, destinationOffset: toOffset * 4, size: count * 4)
        b.endEncoding()
    }

    /// Zero-fills `count` floats of a buffer (blit).
    static func zero(_ cb: any MTLCommandBuffer, _ buf: any MTLBuffer, count: Int) throws {
        if count <= 0 { return }
        guard let b = cb.makeBlitCommandEncoder() else { throw FilterError.gpuUnavailable("blit") }
        b.fill(buffer: buf, range: 0..<(count * 4), value: 0)
        b.endEncoding()
    }

    /// Runs `gpu` or `cpu` per `backend`: `.gpu` throws when the GPU can't take the job, `.auto`
    /// falls back to the CPU on any GPU failure.
    static func run<T>(_ backend: Backend, _ name: String, fits: Bool, gpu: () throws -> T, cpu: () -> T) throws -> T {
        switch backend {
        case .cpu:
            return cpu()
        case .gpu:
            guard fits else { throw FilterError.gpuUnsupported(name) }
            return try gpu()
        case .auto:
            if fits, AlgoGPU.isAvailable, let r = try? gpu() { return r }
            return cpu()
        }
    }

    /// Whether the GPU path can take an image of this size.
    static func gpuFits(_ w: Int, _ h: Int, _ ch: Int) -> Bool {
        w > 0 && h > 0 && max(w, h) <= 65_536 && w * h * max(ch, 1) < Int(UInt32.max) / 2
    }
}
