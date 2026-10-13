// Interleaved Float image regions: the working buffer every CPU algorithm reads and writes.
// Port of photocraft-algo's `Image` (crates/algo/src/image.rs), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

/// How samples outside an image are read.
public enum EdgeMode: Sendable, Codable {
    /// Zero (transparent).
    case transparent
    /// Clamp to the nearest edge pixel.
    case repeatEdge
    /// Wrap around.
    case wrap
}

/// A rectangle of interleaved, normalised samples (alpha last when present).
public struct FloatImage: Sendable, Equatable {
    public var rect: PixelRect
    public var channels: Int
    public var data: [Float]

    public init(rect: PixelRect, channels: Int) {
        self.rect = rect; self.channels = channels
        self.data = [Float](repeating: 0, count: rect.area * channels)
    }

    public init(rect: PixelRect, channels: Int, data: [Float]) {
        precondition(data.count == rect.area * channels, "FloatImage: data size mismatch")
        self.rect = rect; self.channels = channels; self.data = data
    }

    /// Reads `rect` from a surface.
    public init(surface: Surface, rect: PixelRect) {
        self.init(rect: rect, channels: surface.channels, data: surface.readRegion(rect))
    }

    /// Reads `rect`, repeating the nearest pixel of `extent` outside it — how Photoshop treats the
    /// canvas edge when filtering a layer.
    public init(surface: Surface, rect: PixelRect, clampedTo extent: PixelRect) {
        let inner = rect.intersect(extent)
        if inner.isEmpty || inner == rect { self.init(surface: surface, rect: rect); return }
        let src = FloatImage(surface: surface, rect: inner)
        self.init(rect: rect, channels: src.channels)
        // Each row copies the inner span and repeats its first and last pixel outwards.
        let ch = channels, w = rect.width, iw = inner.width
        let left = Int(inner.x0) - Int(rect.x0), right = Int(rect.x1) - Int(inner.x1)
        data.withUnsafeMutableBufferPointer { db in
            src.data.withUnsafeBufferPointer { sb in
                let d = db.baseAddress!, s = sb.baseAddress!
                var y = Int(rect.y0)
                while y < Int(rect.y1) {
                    let sy = y < Int(inner.y0) ? Int(inner.y0) : (y >= Int(inner.y1) ? Int(inner.y1) - 1 : y)
                    let srow = s + (sy - Int(inner.y0)) * iw * ch
                    let drow = d + (y - Int(rect.y0)) * w * ch
                    var x = 0
                    while x < left { (drow + x * ch).update(from: srow, count: ch); x += 1 }
                    (drow + left * ch).update(from: srow, count: iw * ch)
                    x = 0
                    while x < right { (drow + (left + iw + x) * ch).update(from: srow + (iw - 1) * ch, count: ch); x += 1 }
                    y += 1
                }
            }
        }
    }

    public var width: Int { rect.width }
    public var height: Int { rect.height }

    /// Sample index of document pixel (x, y), which must be inside `rect`.
    @inlinable public func index(x: Int32, y: Int32) -> Int {
        (Int(y - rect.y0) * rect.width + Int(x - rect.x0)) * channels
    }

    /// The pixel at document (x, y) with `edge` behaviour outside `rect`.
    public func sample(x: Int32, y: Int32, edge: EdgeMode) -> ArraySlice<Float> {
        var sx = x, sy = y
        if !rect.contains(x: x, y: y) {
            switch edge {
            case .transparent: return ArraySlice(repeating: 0, count: channels)
            case .repeatEdge:
                sx = min(max(x, rect.x0), rect.x1 - 1); sy = min(max(y, rect.y0), rect.y1 - 1)
            case .wrap:
                let w = Int32(rect.width), h = Int32(rect.height)
                sx = rect.x0 + ((x - rect.x0) % w + w) % w
                sy = rect.y0 + ((y - rect.y0) % h + h) % h
            }
        }
        let i = index(x: sx, y: sy)
        return data[i..<i + channels]
    }

    /// The sample index `sample(x:y:edge:)` reads, or nil where it reads transparent zeros.
    func sampleIndex(x: Int32, y: Int32, edge: EdgeMode) -> Int? {
        var sx = x, sy = y
        if !rect.contains(x: x, y: y) {
            switch edge {
            case .transparent: return nil
            case .repeatEdge:
                sx = min(max(x, rect.x0), rect.x1 - 1); sy = min(max(y, rect.y0), rect.y1 - 1)
            case .wrap:
                let w = Int32(rect.width), h = Int32(rect.height)
                sx = rect.x0 + ((x - rect.x0) % w + w) % w
                sy = rect.y0 + ((y - rect.y0) % h + h) % h
            }
        }
        return index(x: sx, y: sy)
    }

    /// Bilinear sample at continuous document coordinates (pixel centres at +0.5).
    public func bilinear(x: Float, y: Float, edge: EdgeMode) -> [Float] {
        let fx = x - 0.5, fy = y - 0.5
        let x0 = Int32(fx.rounded(.down)), y0 = Int32(fy.rounded(.down))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let ia = sampleIndex(x: x0, y: y0, edge: edge), ib = sampleIndex(x: x0 + 1, y: y0, edge: edge)
        let ic = sampleIndex(x: x0, y: y0 + 1, edge: edge), id = sampleIndex(x: x0 + 1, y: y0 + 1, edge: edge)
        let ch = channels
        return [Float](unsafeUninitializedCapacity: ch) { out, n in
            data.withUnsafeBufferPointer { db in
                let d = db.baseAddress
                var k = 0
                while k < ch {
                    let ai = ia.map { d![$0 + k] } ?? 0, bi = ib.map { d![$0 + k] } ?? 0
                    let ci = ic.map { d![$0 + k] } ?? 0, di = id.map { d![$0 + k] } ?? 0
                    out[k] = (ai * (1 - tx) + bi * tx) * (1 - ty) + (ci * (1 - tx) + di * tx) * ty
                    k += 1
                }
            }
            n = ch
        }
    }

    /// Writes this image into a surface at its rect.
    public func write(to surface: inout Surface) { surface.writeRegion(rect, data) }

    /// Multiplies colour channels by alpha (no-op without alpha).
    public mutating func premultiply(hasAlpha: Bool) {
        guard hasAlpha, channels > 1 else { return }
        let ch = channels
        data.withUnsafeMutableBufferPointer { db in
            guard let d = db.baseAddress else { return }
            var p = 0
            while p < db.count {
                let a = d[p + ch - 1]
                var k = 0
                while k < ch - 1 { d[p + k] *= a; k += 1 }
                p += ch
            }
        }
    }

    /// Divides colour channels by alpha; colour is zeroed where alpha ≤ 1e-7 (photocraft's threshold).
    public mutating func unpremultiply(hasAlpha: Bool) {
        guard hasAlpha, channels > 1 else { return }
        let ch = channels
        data.withUnsafeMutableBufferPointer { db in
            guard let d = db.baseAddress else { return }
            var p = 0
            while p < db.count {
                let a = d[p + ch - 1]
                var k = 0
                if a > 1e-7 { while k < ch - 1 { d[p + k] /= a; k += 1 } } else { while k < ch - 1 { d[p + k] = 0; k += 1 } }
                p += ch
            }
        }
    }

    /// Mixes `filtered` back toward `self` (the original) by a per-pixel coverage — selection-aware
    /// filtering, photocraft-algo's `mix_selection`. Coverage is clamped to 0…1. Where the filter
    /// changed alpha (and `hasAlpha`), colour is interpolated premultiplied, so hidden colours don't
    /// leak into feathered edges and alpha-removing filters don't darken them.
    public func mixed(with filtered: FloatImage, coverage: [Float]?, hasAlpha: Bool = false) -> FloatImage {
        guard let cov = coverage else { return filtered }
        var out = filtered
        let ch = channels, a = ch - 1, n = rect.area
        precondition(cov.count >= n && data.count >= n * ch && filtered.data.count >= n * ch, "mixed: buffer sizes")
        if n == 0 { return out }
        out.data.withUnsafeMutableBufferPointer { ob in
            data.withUnsafeBufferPointer { sb in
                filtered.data.withUnsafeBufferPointer { fb in
                    cov.withUnsafeBufferPointer { cb in
                        let o = ob.baseAddress!, src = sb.baseAddress!, f = fb.baseAddress!, cv = cb.baseAddress!
                        var i = 0
                        while i < n {
                            defer { i += 1 }
                            // `min(max(c, 0), 1)` without generic calls (NaN stays NaN, as there).
                            let c0 = cv[i]
                            let k = c0 <= 0 ? 0 : (c0 > 1 ? 1 : c0)
                            let p = i * ch
                            if k >= 1 { continue }
                            if k <= 0 { (o + p).update(from: src + p, count: ch); continue }
                            if hasAlpha && ch > 1 {
                                let oa = src[p + a], fa = f[p + a]
                                if oa != fa {
                                    let ma = oa + (fa - oa) * k
                                    let ow = oa * (1 - k), fw = fa * k
                                    var c = 0
                                    while c < a { o[p + c] = ma > 0 ? (src[p + c] * ow + f[p + c] * fw) / ma : 0; c += 1 }
                                    o[p + a] = ma
                                    continue
                                }
                            }
                            var c = 0
                            while c < ch { let v = src[p + c]; o[p + c] = v + (f[p + c] - v) * k; c += 1 }
                        }
                    }
                }
            }
        }
        return out
    }

}
