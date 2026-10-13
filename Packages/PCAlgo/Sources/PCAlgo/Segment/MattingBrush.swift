// Port of photocraft-algo (crates/algo/src/matting/brush.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Select and Mask's Refine Edge Brush: strokes that set where edge refinement happens. Adding
// marks an area as unknown (coverage estimated from the image, so hair beyond the band is picked
// up); restoring (Alt) keeps the original edge. Strokes apply in order. The estimate projects
// each painted pixel's colour on the line between the mean known foreground and background
// colours around it (normalised convolution; the colour-line model of Levin, Lischinski & Weiss,
// CVPR 2006, with one colour per side and window).

import Foundation
import PCFoundation

/// One Refine Edge Brush stroke, in document pixels.
public struct EdgeStroke: Sendable, Hashable {
    /// The stroke's path (a single point paints a dab).
    public var points: [SIMD2<Float>]
    /// Brush diameter in pixels.
    public var size: Float
    /// Add to the refinement area (true) or restore the original edge (false).
    public var add: Bool
    public init(points: [SIMD2<Float>], size: Float, add: Bool) { self.points = points; self.size = size; self.add = add }
}

/// The painted area: signed coverage (+1 refined, −1 restored, 0 untouched) over `bounds`.
public struct EdgeBrush: Sendable, Hashable {
    /// Brush diameters the strokes may use.
    public static let sizeRange: ClosedRange<Float> = 1...5000
    /// Most pixels the strokes of one brush may sweep (Σ length × size + size² per stroke).
    public static let maxSweptArea = Double(UInt64(1) << 28)

    public private(set) var bounds: PixelRect
    /// Coverage × 127, row-major over `bounds`.
    var v: [Int8]
    /// Bounds of the added (positive) coverage.
    public private(set) var addedBounds: PixelRect
    /// Box radius of the colour estimate (it reads up to four times as far).
    public private(set) var window: Int

    /// The area `strokes` sweep; non-finite strokes count as infinite.
    public static func sweptArea(_ strokes: [EdgeStroke]) -> Double {
        var total = 0.0
        for s in strokes {
            let size = Double(clampf(s.size, sizeRange.lowerBound, sizeRange.upperBound))
            var len = 0.0
            if s.points.count >= 2 { for i in 1..<s.points.count { len += Double(hypotf(s.points[i].x - s.points[i - 1].x, s.points[i].y - s.points[i - 1].y)) } }
            total += len.isFinite ? len * size + size * size : .infinity
        }
        return total
    }

    /// Rasterises `strokes` (clipped to `canvas`); nil when they paint nothing or sweep more than
    /// `maxSweptArea`.
    public init?(_ strokes: [EdgeStroke], canvas: PixelRect) {
        if EdgeBrush.sweptArea(strokes) > EdgeBrush.maxSweptArea { return nil }
        let usable = strokes.filter { s in s.size.isFinite && !s.points.isEmpty && s.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }
        func radius(_ s: EdgeStroke) -> Float { clampf(s.size, EdgeBrush.sizeRange.lowerBound, EdgeBrush.sizeRange.upperBound) / 2 }
        func strokeBounds(_ s: EdgeStroke) -> PixelRect {
            let r = radius(s)
            return s.points.reduce(PixelRect.empty) { $0.union(SegmentKit.dabBounds($1, r)) }.intersect(canvas)
        }
        let bbox = usable.reduce(PixelRect.empty) { $0.union(strokeBounds($1)) }
        if bbox.isEmpty { return nil }
        let bw = bbox.width
        var v = [Int8](repeating: 0, count: bw * bbox.height)
        var maxAdd: Float = 0
        for s in usable {
            let sb = strokeBounds(s)
            if sb.isEmpty { continue }
            let r = radius(s)
            if s.add { maxAdd = Float.maximum(maxAdd, 2 * r) }
            let sw = sb.width
            var cov = [Float](repeating: 0, count: sw * sb.height)
            // The stroke's coverage: the most any of its segments gives.
            for (a, b) in SegmentKit.segments(s.points, r) {
                let seg = SegmentKit.dabBounds(a, r).union(SegmentKit.dabBounds(b, r)).intersect(sb)
                if seg.isEmpty { continue }
                for y in seg.y0..<seg.y1 {
                    for x in seg.x0..<seg.x1 {
                        let c = SegmentKit.capsule(SIMD2(Float(x) + 0.5, Float(y) + 0.5), a, b, r)
                        let i = Int(y - sb.y0) * sw + Int(x - sb.x0)
                        if c > cov[i] { cov[i] = c }
                    }
                }
            }
            let target: Float = s.add ? 1 : -1
            for y in sb.y0..<sb.y1 {
                for x in sb.x0..<sb.x1 {
                    let c = cov[Int(y - sb.y0) * sw + Int(x - sb.x0)]
                    if c <= 0 { continue }
                    let i = Int(y - bbox.y0) * bw + Int(x - bbox.x0)
                    let cur = Float(v[i]) / 127
                    v[i] = Int8(clampf(((cur + (target - cur) * c) * 127).rounded(), -127, 127))
                }
            }
        }
        if v.allSatisfy({ $0 == 0 }) { return nil }
        var x0 = Int32.max, y0 = Int32.max, x1 = Int32.min, y1 = Int32.min
        for row in 0..<bbox.height {
            let line = v[(row * bw)..<(row * bw + bw)]
            guard let first = line.firstIndex(where: { $0 > 0 }), let last = line.lastIndex(where: { $0 > 0 }) else { continue }
            let y = bbox.y0 + Int32(row)
            x0 = min(x0, bbox.x0 + Int32(first - row * bw)); x1 = max(x1, bbox.x0 + Int32(last - row * bw) + 1)
            y0 = min(y0, y); y1 = max(y1, y + 1)
        }
        bounds = bbox
        self.v = v
        addedBounds = x0 < x1 ? PixelRect(x0: x0, y0: y0, x1: x1, y1: y1) : .empty
        window = Int(clampf(maxAdd.rounded(.up), 4, 64))
    }

    /// Signed coverage at document pixel (x, y) (zero outside the painted area).
    public func at(_ x: Int32, _ y: Int32) -> Float {
        if !bounds.contains(x: x, y: y) { return 0 }
        return Float(v[Int(y - bounds.y0) * bounds.width + Int(x - bounds.x0)]) / 127
    }

    /// Signed coverage over `r` (row-major).
    public func read(_ r: PixelRect) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(r.area)
        for y in r.y0..<r.y1 { for x in r.x0..<r.x1 { out.append(at(x, y)) } }
        return out
    }
}

extension SegmentKit {
    /// Coverage (0–1) of a round brush of radius `r` swept from `a` to `b`, at pixel centre `p`.
    static func capsule(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ r: Float) -> Float {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t: Float = len2 > 0 ? clampf(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0, 1) : 0
        let cx = a.x + t * dx, cy = a.y + t * dy
        let d = ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)).squareRoot()
        return clampf(r + 0.5 - d, 0, 1)
    }

    /// The pixels a disc of radius `r` at `p` can touch.
    static func dabBounds(_ p: SIMD2<Float>, _ r: Float) -> PixelRect {
        let lim = Float(Int32.max) / 2
        func lo(_ v: Float) -> Int32 { PCAMath.i32(clampf((v - r - 1).rounded(.down), -lim, lim)) }
        func hi(_ v: Float) -> Int32 { PCAMath.i32(clampf((v + r + 1).rounded(.up), -lim, lim)) }
        return PixelRect(x0: lo(p.x), y0: lo(p.y), x1: hi(p.x), y1: hi(p.y))
    }

    /// The stroke's path as short segments: points closer than r/4 to the last kept one dropped,
    /// long segments split at most r long (photocraft `segments`).
    static func segments(_ points: [SIMD2<Float>], _ r: Float) -> [(SIMD2<Float>, SIMD2<Float>)] {
        guard let first = points.first else { return [] }
        let minStep = Float.maximum(r / 4, 0.5), maxStep = Float.maximum(r, 2)
        var kept = [first]
        for p in points.dropFirst() {
            let last = kept.last ?? first
            if hypotf(p.x - last.x, p.y - last.y) >= minStep { kept.append(p) }
        }
        if let last = kept.last, let end = points.last, last != end { kept.append(end) }
        if kept.count == 1 { return [(first, first)] }
        var out: [(SIMD2<Float>, SIMD2<Float>)] = []
        for i in 1..<kept.count {
            let a = kept[i - 1], b = kept[i]
            let pieces = Int(clampf((hypotf(b.x - a.x, b.y - a.y) / maxStep).rounded(.up), 1, 1e6))
            func at(_ k: Int) -> SIMD2<Float> {
                let t = Float(k) / Float(pieces)
                return SIMD2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            }
            for k in 0..<pieces { out.append((at(k), at(k + 1))) }
        }
        return out
    }

    /// Coverage estimated from the image where `brush` (signed, w × h) adds: each pixel's colour
    /// projected on the line between the mean known foreground and background colours within
    /// `window` px (or 4 × window where none is that close). Pixels with no foreground or
    /// background nearby, or no contrast between them, keep `m` (photocraft `estimate`).
    static func brushEstimate(_ img: SegmentRGBImage, _ m: [Float], _ brush: [Float], _ w: Int, _ h: Int, _ window: Int) -> [Float] {
        let n = w * h
        func known(_ wantFG: Bool) -> [Float] {
            (0..<n).map { i in
                let mv = i < m.count ? m[i] : 0, bv = i < brush.count ? brush[i] : 0
                return bv <= 0 && (wantFG ? mv >= 0.98 : mv <= 0.02) ? 1 : 0
            }
        }
        let wf = known(true), wb = known(false)
        func means(_ wt: [Float], _ r: Int) -> ([Float], [[Float]]) {
            let sums = (0..<3).map { c in Matting.boxMean((0..<n).map { img.px[$0][c] * wt[$0] }, w: w, h: h, r: r) }
            return (Matting.boxMean(wt, w: w, h: h, r: r), sums)
        }
        let near = [means(wf, window), means(wb, window)]
        let far = [means(wf, window * 4), means(wb, window * 4)]
        func pick(_ ds: ([Float], [[Float]]), _ i: Int) -> SIMD3<Float>? {
            let d = ds.0[i]
            if !(d >= 1e-4) { return nil }
            return SIMD3(ds.1[0][i] / d, ds.1[1][i] / d, ds.1[2][i] / d)
        }
        func mean(_ k: Int, _ i: Int) -> SIMD3<Float>? { pick(near[k], i) ?? pick(far[k], i) }
        var out = m
        for i in 0..<out.count where i < brush.count && brush[i] > 0 {
            guard let fm = mean(0, i), let bm = mean(1, i), i < img.px.count else { continue }
            let px = img.px[i]
            var num: Float = 0, den: Float = 0
            for c in 0..<3 {
                num += (px[c] - bm[c]) * (fm[c] - bm[c])
                den += (fm[c] - bm[c]) * (fm[c] - bm[c])
            }
            if den > 1e-4 { out[i] = clampf(num / den, 0, 1) }
        }
        return out
    }
}
