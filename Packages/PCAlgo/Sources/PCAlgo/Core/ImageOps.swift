// Port of photocraft-algo (crates/algo/src/image.rs, fxutil.rs, par.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Sampling helpers on FloatImage with photocraft `Image` semantics (0 outside the image, edge
// policies relative to an area, premultiplied bilinear sampling), plus the parallel-loop helper
// the CPU references use in place of rayon.

import Dispatch
import PCFoundation

/// A value handed to concurrent loop bodies that write disjoint parts of a buffer.
struct UnsafeSendable<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// `body(i)` for `0..<n`, in parallel (photocraft's rayon `par_iter`). Results never depend on
/// the scheduling: each index writes its own output.
@inline(__always)
func parallelFor(_ n: Int, _ body: (Int) -> Void) {
    if n <= 0 { return }
    if n == 1 { body(0); return }
    withoutActuallyEscaping(body) { b in
        // Bodies write disjoint outputs; the closure itself needn't be Sendable.
        nonisolated(unsafe) let run = b
        DispatchQueue.concurrentPerform(iterations: n) { run($0) }
    }
}

/// `body(range)` over chunks of `0..<n`, in parallel (fewer dispatches for cheap rows).
@inline(__always)
func parallelChunks(_ n: Int, minChunk: Int = 1, _ body: (Range<Int>) -> Void) {
    if n <= 0 { return }
    let workers = max(1, min(n / max(minChunk, 1), 64))
    if workers <= 1 { body(0..<n); return }
    let per = (n + workers - 1) / workers
    withoutActuallyEscaping(body) { b in
        nonisolated(unsafe) let run = b
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            let lo = w * per, hi = min(n, lo + per)
            if lo < hi { run(lo..<hi) }
        }
    }
}

extension FloatImage {
    /// Sample at integer document coordinates; 0 outside (photocraft `Image::get`).
    @inline(__always)
    func get(_ x: Int32, _ y: Int32, _ c: Int) -> Float {
        if x < rect.x0 || x >= rect.x1 || y < rect.y0 || y >= rect.y1 { return 0 }
        return data[(Int(y - rect.y0) * rect.width + Int(x - rect.x0)) * channels + c]
    }

    /// Sample with an edge policy relative to `area` (photocraft `Image::get_edge`).
    @inline(__always)
    func getEdge(_ x: Int32, _ y: Int32, _ c: Int, _ edge: EdgeMode, _ area: PixelRect) -> Float {
        if area.isEmpty { return 0 }
        if area.contains(x: x, y: y) { return get(x, y, c) }
        switch edge {
        case .transparent: return 0
        case .repeatEdge:
            return get(min(max(x, area.x0), area.x1 - 1), min(max(y, area.y0), area.y1 - 1), c)
        case .wrap:
            let w = Int32(max(area.width, 1)), h = Int32(max(area.height, 1))
            return get(area.x0 + euclidMod(x - area.x0, w), area.y0 + euclidMod(y - area.y0, h), c)
        }
    }

    /// The samples inside `out` (0 outside this image) — photocraft `Image::crop`.
    func crop(_ out: PixelRect) -> FloatImage {
        if out == rect { return self }
        var res = FloatImage(rect: out, channels: channels)
        let inner = out.intersect(rect)
        if inner.isEmpty { return res }
        let n = channels, span = inner.width * n
        data.withUnsafeBufferPointer { s in
            res.data.withUnsafeMutableBufferPointer { d in
                for y in inner.y0..<inner.y1 {
                    let si = (Int(y - rect.y0) * rect.width + Int(inner.x0 - rect.x0)) * n
                    let di = (Int(y - out.y0) * out.width + Int(inner.x0 - out.x0)) * n
                    for i in 0..<span { d[di + i] = s[si + i] }
                }
            }
        }
        return res
    }

    /// Bilinear sample of the premultiplied pixel at `(x, y)` (pixel centres at .5), written to
    /// `out` as straight colour with alpha last (photocraft `Image::sample`). Taps (0,0) (1,0)
    /// (0,1) (1,1), zero-weight taps skipped; NaN / huge coordinates saturate as Rust's `as i32`.
    func samplePremul(_ x: Float, _ y: Float, _ edge: EdgeMode, _ area: PixelRect, _ alpha: Bool, _ out: inout [Float]) {
        let fx = x - 0.5, fy = y - 0.5
        let fx0 = fx.rounded(.down), fy0 = fy.rounded(.down)
        let ax = fx - fx0, ay = fy - fy0
        let x0 = PCAMath.floorToInt(fx0), y0 = PCAMath.floorToInt(fy0)
        let n = channels
        for i in 0..<n { out[i] = 0 }
        var accA: Float = 0
        let nc = alpha ? n - 1 : n
        @inline(__always) func tap(_ dx: Int32, _ dy: Int32, _ w: Float) {
            if w <= 0 { return }
            let a: Float = alpha ? getEdge(x0 + dx, y0 + dy, n - 1, edge, area) : 1
            for c in 0..<nc { out[c] += getEdge(x0 + dx, y0 + dy, c, edge, area) * a * w }
            accA += a * w
        }
        tap(0, 0, (1 - ax) * (1 - ay))
        tap(1, 0, ax * (1 - ay))
        tap(0, 1, (1 - ax) * ay)
        tap(1, 1, ax * ay)
        if alpha {
            if accA > 0 { for c in 0..<(n - 1) { out[c] /= accA } }
            out[n - 1] = accA
        }
    }
}

/// Euclidean remainder (photocraft `rem_euclid`).
@inline(__always)
func euclidMod(_ a: Int32, _ b: Int32) -> Int32 {
    let r = a % b
    return r < 0 ? r + abs(b) : r
}

@inline(__always)
func euclidMod(_ a: Float, _ b: Float) -> Float {
    let r = fmodf(a, b)
    return r < 0 ? r + abs(b) : r
}

/// Multiplies colour channels by alpha in place (photocraft `image::premultiply`).
func premultiply(_ data: inout [Float], _ n: Int, _ alpha: Bool) {
    guard alpha, n > 0 else { return }
    data.withUnsafeMutableBufferPointer { d in
        var p = 0
        while p < d.count {
            let a = d[p + n - 1]
            for c in 0..<(n - 1) { d[p + c] *= a }
            p += n
        }
    }
}

/// Inverse of `premultiply`: colour zeroed where alpha ≤ 1e-7 (photocraft `image::unpremultiply`).
func unpremultiply(_ data: inout [Float], _ n: Int, _ alpha: Bool) {
    guard alpha, n > 0 else { return }
    data.withUnsafeMutableBufferPointer { d in
        var p = 0
        while p < d.count {
            let a = d[p + n - 1]
            for c in 0..<(n - 1) { d[p + c] = a > 1e-7 ? d[p + c] / a : 0 }
            p += n
        }
    }
}

/// Document coordinates of the `i`th pixel of `out` (photocraft `fxutil::xy`).
@inline(__always)
func pixelXY(_ out: PixelRect, _ i: Int) -> (Int32, Int32) {
    let w = out.width
    return (out.x0 + Int32(i % w), out.y0 + Int32(i / w))
}

@inline(__always)
func clampf(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

@inline(__always)
func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    if e1 <= e0 { return x >= e1 ? 1 : 0 }
    let t = clampf((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}

extension PixelRect {
    /// Grown by `d` on every side (photocraft `Rect::inflate`).
    func inflate(_ d: Int32) -> PixelRect { outset(by: d) }
}
