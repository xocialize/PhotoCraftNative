// Port of photocraft-compose (crates/compose/src/lib.rs, `Buffer`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The CPU compositor's working buffer: straight-alpha RGBA floats over a rectangle (photocraft
// `Buffer`), plus the parallel-loop helpers the CPU reference uses (photocraft uses rayon and scoped
// threads; here `DispatchQueue.concurrentPerform`, deterministic because every unit writes only its
// own pixels).

import Dispatch
import PCFoundation

/// Straight-alpha RGBA over `rect`, row-major.
public struct RGBABuffer: Sendable, Equatable {
    public var rect: PixelRect
    public var px: [SIMD4<Float>]

    public init(rect: PixelRect, px: [SIMD4<Float>]) {
        precondition(px.count == rect.area, "RGBABuffer: pixel count")
        self.rect = rect; self.px = px
    }

    public init(transparent rect: PixelRect) {
        self.rect = rect; self.px = [SIMD4<Float>](repeating: .zero, count: rect.area)
    }

    public init(rect: PixelRect, filled c: SIMD4<Float>) {
        self.rect = rect; self.px = [SIMD4<Float>](repeating: c, count: rect.area)
    }

    /// From a FloatImage of 1 (grey), 2 (grey + alpha), 3 (RGB, opaque) or 4 (RGBA) channels.
    public init(_ image: FloatImage) {
        rect = image.rect
        let n = image.rect.area, ch = image.channels
        var out = [SIMD4<Float>](repeating: .zero, count: n)
        image.data.withUnsafeBufferPointer { d in
            for i in 0..<n {
                let o = i * ch
                switch ch {
                case 1: out[i] = SIMD4(d[o], d[o], d[o], 1)
                case 2: out[i] = SIMD4(d[o], d[o], d[o], d[o + 1])
                case 3: out[i] = SIMD4(d[o], d[o + 1], d[o + 2], 1)
                default: out[i] = SIMD4(d[o], d[o + 1], d[o + 2], d[o + 3])
                }
            }
        }
        px = out
    }

    /// As a 4-channel FloatImage.
    public var floatImage: FloatImage {
        var data = [Float](repeating: 0, count: px.count * 4)
        for (i, p) in px.enumerated() { data[i * 4] = p.x; data[i * 4 + 1] = p.y; data[i * 4 + 2] = p.z; data[i * 4 + 3] = p.w }
        return FloatImage(rect: rect, channels: 4, data: data)
    }

    @inline(__always) public func get(_ x: Int32, _ y: Int32) -> SIMD4<Float> {
        px[Int(y - rect.y0) * rect.width + Int(x - rect.x0)]
    }

    /// The pixels of `r` (inside `rect`).
    public func cropped(to r: PixelRect) -> RGBABuffer {
        if r == rect { return self }
        var out = RGBABuffer(transparent: r)
        let inter = r.intersect(rect)
        if inter.isEmpty { return out }
        for y in inter.y0..<inter.y1 {
            let s = Int(y - rect.y0) * rect.width + Int(inter.x0 - rect.x0)
            let d = Int(y - r.y0) * r.width + Int(inter.x0 - r.x0)
            for k in 0..<inter.width { out.px[d + k] = px[s + k] }
        }
        return out
    }

    /// Writes `part` over its rect (inside `rect`).
    public mutating func paste(_ part: RGBABuffer) {
        let inter = part.rect.intersect(rect)
        if inter.isEmpty { return }
        for y in inter.y0..<inter.y1 {
            let s = Int(y - part.rect.y0) * part.rect.width + Int(inter.x0 - part.rect.x0)
            let d = Int(y - rect.y0) * rect.width + Int(inter.x0 - rect.x0)
            for k in 0..<inter.width { px[d + k] = part.px[s + k] }
        }
    }

    /// Flattened over an opaque background colour.
    public func over(background bg: SIMD3<Float>) -> RGBABuffer {
        var out = self
        for i in out.px.indices {
            let p = out.px[i]
            out.px[i] = SIMD4(p.x * p.w + bg.x * (1 - p.w), p.y * p.w + bg.y * (1 - p.w), p.z * p.w + bg.z * (1 - p.w), 1)
        }
        return out
    }
}

// MARK: - Parallel helpers

/// A value handed to concurrent workers that only touch disjoint parts of it.
struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}

/// Units of work below this many pixels run on the calling thread.
let parallelMinimum = 1 << 15

/// Runs `body(range)` over `0..<count` split into contiguous chunks, in parallel when `work`
/// (pixels or similar units) is large enough. Each index is visited exactly once.
func parallelChunks(_ count: Int, work: Int, _ body: (Range<Int>) -> Void) {
    if count <= 0 { return }
    let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
    if work < parallelMinimum || count == 1 || cores == 1 {
        body(0..<count)
        return
    }
    let chunks = min(count, cores * 4)
    let per = (count + chunks - 1) / chunks
    withoutActuallyEscaping(body) { b in
        let box = UnsafeSendable(b)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let lo = c * per, hi = min(count, lo + per)
            if lo < hi { box.value(lo..<hi) }
        }
    }
}

/// `parallelChunks` over the rows of a `w × h` buffer: `body(y)` for every row.
func parallelRows(_ h: Int, width w: Int, _ body: (Int) -> Void) {
    parallelChunks(h, work: w * h) { r in for y in r { body(y) } }
}

import Foundation
