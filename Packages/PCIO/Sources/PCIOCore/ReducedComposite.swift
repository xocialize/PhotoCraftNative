// Area-averaged reductions of a document's composite: the `.pcraft` previews (AB-T-0259).
//
// `DocumentCompositor.reduced` is one composite of the whole canvas, averaged down. Its default
// composites the canvas a band of rows at a time through `composite(_:rect:)`; a compositor that
// can reduce straight from its own output (PCRender's `renderReduced`) overrides it. A second,
// smaller reduction is taken from the first (`ReducedComposite.reduce(_:width:height:of:to:_:)`)
// instead of compositing the canvas again.

import PCDocument
import PCFoundation

extension DocumentCompositor {
    public func reduced(_ document: Document, width: Int, height: Int) throws -> [SIMD4<Float>] {
        try ReducedComposite.reduce(document, width: width, height: height, compositor: self)
    }

    public func reduced(_ document: Document, width: Int, height: Int, damage: PixelRect) throws -> (rect: PixelRect, pixels: [SIMD4<Float>]) {
        let rect = ReducedComposite.cells(meeting: damage, canvas: document.size, width: width, height: height)
        if rect.isEmpty { return (rect, []) }
        let whole = try reduced(document, width: width, height: height)
        return (rect, ReducedComposite.crop(whole, width: width, rect))
    }
}

/// Area-averaged reductions of a composite (`DocumentCompositor.reduced`).
public enum ReducedComposite {
    /// The source pixels `lo ..< hi` (of `f`) that output pixel `t` (of `n`) averages: PCRender's
    /// `renderReduced` cells.
    @inline(__always)
    public static func span(_ t: Int, _ f: Int, _ n: Int) -> (lo: Int, hi: Int) {
        let lo = t * f / n
        return (lo, min(max((t + 1) * f / n, lo + 1), f))
    }

    /// For each of `f` source pixels, the output pixel (of `n`) whose span holds it.
    static func cells(_ f: Int, _ n: Int) -> [Int] {
        var m = [Int](repeating: 0, count: f)
        for t in 0 ..< n {
            let (a, z) = span(t, f, n)
            for i in a ..< z { m[i] = t }
        }
        return m
    }

    /// The output pixels (of a `width` × `height` reduction of a `canvas`-sized composite) whose
    /// spans meet `damage`, as a rect from (0, 0): empty when `damage` misses the canvas.
    public static func cells(meeting damage: PixelRect, canvas: PixelSize, width: Int, height: Int) -> PixelRect {
        let W = canvas.width, H = canvas.height
        let d = damage.intersect(PixelRect(size: canvas))
        guard W > 0, H > 0, width > 0, height > 0, !d.isEmpty else { return .empty }
        let w = min(width, W), h = min(height, H)
        // The cell holding canvas column `x` (of `f`, in `n` cells): the last whose span starts at or before it.
        func cell(_ x: Int, _ f: Int, _ n: Int) -> Int { max((x + 1) * n - 1, 0) / f }
        let x0 = Int(d.x0), x1 = Int(d.x1), y0 = Int(d.y0), y1 = Int(d.y1)
        return PixelRect(x0: Int32(cell(x0, W, w)), y0: Int32(cell(y0, H, h)), x1: Int32(cell(x1 - 1, W, w) + 1), y1: Int32(cell(y1 - 1, H, h) + 1))
    }

    /// The pixels of `rect` from a row-major image `width` wide.
    public static func crop(_ image: [SIMD4<Float>], width: Int, _ rect: PixelRect) -> [SIMD4<Float>] {
        var out = [SIMD4<Float>]()
        out.reserveCapacity(max(0, rect.area))
        for y in Int(rect.y0) ..< Int(rect.y1) { out += image[y * width + Int(rect.x0) ..< y * width + Int(rect.x1)] }
        return out
    }

    /// `image` (`width` wide) with `pixels` written over `rect`.
    public static func patch(_ image: inout [SIMD4<Float>], width: Int, _ rect: PixelRect, _ pixels: [SIMD4<Float>]) {
        let w = rect.width
        for (j, y) in (Int(rect.y0) ..< Int(rect.y1)).enumerated() {
            image.replaceSubrange(y * width + Int(rect.x0) ..< y * width + Int(rect.x1), with: pixels[j * w ..< (j + 1) * w])
        }
    }

    /// `DocumentCompositor.reduced` through `compositor.composite`, a band of rows at a time: what
    /// any compositor can do. The samples are read as `Surface.readRGBA` reads them.
    public static func reduce(_ doc: Document, width: Int, height: Int, compositor: some DocumentCompositor) throws -> [SIMD4<Float>] {
        let W = doc.size.width, H = doc.size.height
        let w = min(max(width, 1), max(W, 1)), h = min(max(height, 1), max(H, 1))
        guard W > 0, H > 0 else { return [SIMD4<Float>](repeating: .zero, count: w * h) }
        let col = cells(W, w), row = cells(H, h)
        let fmt = doc.pixelFormat
        var acc = [SIMD4<Float>](repeating: .zero, count: w * h)
        var y = 0
        while y < H {
            let band = PixelRect(x0: 0, y0: Int32(y), x1: Int32(W), y1: Int32(min(y + Int(tileSize), H)))
            var s = Surface(format: fmt)
            s.writeRegion(band, try compositor.composite(doc, rect: band))
            let rgba = s.readRGBA(band)
            for j in 0 ..< band.height {
                let o = row[y + j] * w
                for i in 0 ..< W {
                    let p = rgba[j * W + i]
                    // Premultiplied, so transparent pixels don't darken the edges.
                    acc[o + col[i]] += SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w)
                }
            }
            y = Int(band.y1)
        }
        for k in acc.indices {
            let (x0, x1) = span(k % w, W, w), (y0, y1) = span(k / w, H, h)
            acc[k] = straight(acc[k], area: Float((x1 - x0) * (y1 - y0)))
        }
        return acc
    }

    /// `image`, a `width` × `height` reduction of a `canvas`-sized composite (`reduced`), reduced
    /// further to `w` × `h`. Each output pixel averages the canvas pixels its own span covers,
    /// taken from the cells of `image` that overlap them, each weighted by its overlap. Where the
    /// cells' edges fall on the output's (4096² to 1024² and 256², or any `image` of the canvas's
    /// own size) that is the reduction of the canvas itself; elsewhere a cell counts as even
    /// across its area.
    public static func reduce(_ image: [SIMD4<Float>], width: Int, height: Int, of canvas: PixelSize, to w: Int, _ h: Int) -> [SIMD4<Float>] {
        let W = canvas.width, H = canvas.height
        guard W > 0, H > 0, width > 0, height > 0, w > 0, h > 0, image.count == width * height else {
            return [SIMD4<Float>](repeating: .zero, count: max(0, w) * max(0, h))
        }
        let w = min(w, W), h = min(h, H)
        // For each output column (row): the image's cells it takes, with their overlap in canvas pixels.
        func weights(_ f: Int, _ n1: Int, _ n2: Int) -> [[(cell: Int, weight: Float)]] {
            let cell = cells(f, n1)
            return (0 ..< n2).map { t in
                let (a, z) = span(t, f, n2)
                return (cell[a] ... cell[z - 1]).map { c in
                    let (ca, cz) = span(c, f, n1)
                    return (c, Float(min(z, cz) - max(a, ca)))
                }
            }
        }
        let wx = weights(W, width, w), wy = weights(H, height, h)
        var out = [SIMD4<Float>](repeating: .zero, count: w * h)
        for ty in 0 ..< h {
            for tx in 0 ..< w {
                var sum = SIMD4<Float>.zero, area: Float = 0
                for (cy, ky) in wy[ty] {
                    for (cx, kx) in wx[tx] {
                        let p = image[cy * width + cx], k = kx * ky
                        sum += SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w) * k
                        area += k
                    }
                }
                out[ty * w + tx] = straight(sum, area: area)
            }
        }
        return out
    }

    /// A premultiplied sum over `area` pixels as straight RGBA (transparent: all zero).
    @inline(__always)
    static func straight(_ p: SIMD4<Float>, area: Float) -> SIMD4<Float> {
        p.w > 0 ? SIMD4(p.x / p.w, p.y / p.w, p.z / p.w, p.w / max(area, 1)) : .zero
    }
}
