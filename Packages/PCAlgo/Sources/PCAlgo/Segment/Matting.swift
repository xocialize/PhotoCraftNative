// Port of photocraft-algo (crates/algo/src/matting.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edge refinement (Select and Mask / Refine Edge) and colour decontamination:
// * Soft edges from the guided filter (He, Sun & Tang, ECCV 2010 / PAMI 2013): filtering the
//   binary selection with the image as guide fits α ≈ aᵀI + b in every window, so the mask takes
//   on the image's soft transitions inside a band of `radius` pixels around the edge; "smart
//   radius" adapts the band to the transition width observed in the image.
// * Then, in Photoshop's order: Smooth, Feather (Gaussian σ = feather/2), Contrast and Shift Edge
//   (octagonal grey dilation / erosion, MattingMorphology.swift).
// * Decontaminate Colors replaces fringe colours by the normalised-convolution average of nearby
//   fully selected pixels.
// Work is tiled (256 px plus the halo): only tiles near the selection boundary are processed.
//
// Metal: the box means and the colour guided filter (Shaders/Segment.metal) — Float
// running sums against the CPU's Double prefix sums, within ~1e-4 (`.gpu`; `.auto` is the CPU,
// see the measurements in the report).

import Foundation
import PCFoundation

/// Select and Mask parameters, Photoshop's units (photocraft `RefineParams`).
public struct RefineParams: Codable, Sendable, Hashable {
    /// Edge-detection band radius in pixels (0 = no edge detection).
    public var radius: Float = 0
    /// Adapt the band to the edge's observed softness.
    public var smartRadius: Bool = false
    /// 0–100.
    public var smooth: Float = 0
    /// Pixels.
    public var feather: Float = 0
    /// 0–100.
    public var contrast: Float = 0
    /// −100–100: 100 % moves the edge by max(radius, 4) px; fractions blend the neighbouring
    /// whole-pixel shifts.
    public var shiftEdge: Float = 0

    public init(radius: Float = 0, smartRadius: Bool = false, smooth: Float = 0, feather: Float = 0, contrast: Float = 0, shiftEdge: Float = 0) {
        self.radius = radius; self.smartRadius = smartRadius; self.smooth = smooth; self.feather = feather
        self.contrast = contrast; self.shiftEdge = shiftEdge
    }

    enum CodingKeys: String, CodingKey { case radius, smartRadius, smooth, feather, contrast, shiftEdge }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        radius = try c.decodeIfPresent(Float.self, forKey: .radius) ?? 0
        smartRadius = try c.decodeIfPresent(Bool.self, forKey: .smartRadius) ?? false
        smooth = try c.decodeIfPresent(Float.self, forKey: .smooth) ?? 0
        feather = try c.decodeIfPresent(Float.self, forKey: .feather) ?? 0
        contrast = try c.decodeIfPresent(Float.self, forKey: .contrast) ?? 0
        shiftEdge = try c.decodeIfPresent(Float.self, forKey: .shiftEdge) ?? 0
    }

    var gfRadius: Int { Int(clampf(radius.rounded(.up), 1, 64)) }
    var smoothSigma: Float { clampf(smooth, 0, 100) / 100 * 4 }
    var featherSigma: Float { Float.maximum(feather, 0) / 2 }
    /// Signed shift in pixels, fractional: 100 % is max(radius, 4) px, clamped to ±64.
    var shiftAmount: Float {
        let px = clampf(shiftEdge, -100, 100) / 100 * Float.maximum(radius, 4)
        return px.isFinite ? clampf(px, -64, 64) : 0
    }
    /// How many pixels the mask can move: the farther of the two whole radii a fraction blends.
    var shiftPx: Int32 {
        let px = shiftAmount
        let reach = abs(px).rounded(.up)
        let signed = px.sign == .minus ? -reach : reach
        return signed.isFinite ? PCAMath.i32(signed) : 0
    }
    var usesImage: Bool { radius > 0 }

    /// Pixels read around an output pixel.
    public var halo: Int32 {
        var edge: Int32 = 0
        if usesImage {
            let g = Int32(gfRadius)
            edge = max(PCAMath.i32(radius.rounded(.up)), 2 * g + (smartRadius ? g + 1 : 0))
        }
        return edge + PCAMath.i32((3 * smoothSigma).rounded(.up)) + PCAMath.i32((3 * featherSigma).rounded(.up)) + abs(shiftPx) + 2
    }

    /// How far the refined mask can extend beyond the original.
    public var spread: Int32 {
        (usesImage ? PCAMath.i32(radius.rounded(.up)) : 0) + PCAMath.i32((3 * smoothSigma).rounded(.up))
            + PCAMath.i32((3 * featherSigma).rounded(.up)) + max(shiftPx, 0) + 1
    }
}

/// Select and Mask / Refine Edge (photocraft `matting`).
public enum Matting {
    /// Guided-filter regulariser (colour guide, samples in 0–1).
    public static let eps: Float = 1e-4
    static let tile: Int32 = 256

    /// Box mean with radius `r` (window clipped to the image, divided by the pixel count):
    /// Double prefix sums along rows, then down columns.
    public static func boxMean(_ src: [Float], w: Int, h: Int, r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: w * h)
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { tb in
                let t = UnsafeSendable(tb)
                parallelChunks(h, minChunk: 16) { rows in
                    var pre = [Double](repeating: 0, count: w + 1)
                    for y in rows {
                        for x in 0..<w { pre[x + 1] = pre[x] + Double(s[y * w + x]) }
                        for x in 0..<w {
                            let lo = x > r ? x - r : 0, hi = min(x + r + 1, w)
                            t.value[y * w + x] = Float((pre[hi] - pre[lo]) / Double(hi - lo))
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { ob in
                let o = UnsafeSendable(ob)
                parallelChunks(w, minChunk: 32) { cols in
                    var col = [Double](repeating: 0, count: h + 1)
                    for x in cols {
                        for y in 0..<h { col[y + 1] = col[y] + Double(t[y * w + x]) }
                        for y in 0..<h {
                            let lo = y > r ? y - r : 0, hi = min(y + r + 1, h)
                            o.value[y * w + x] = Float((col[hi] - col[lo]) / Double(hi - lo))
                        }
                    }
                }
            }
        }
        return out
    }

    /// Guided filter with a grayscale guide.
    public static func guidedFilterGray(_ guide: [Float], _ p: [Float], w: Int, h: Int, r: Int, eps: Float) -> [Float] {
        let mi = boxMean(guide, w: w, h: h, r: r), mp = boxMean(p, w: w, h: h, r: r)
        let mip = boxMean(zip(guide, p).map { $0 * $1 }, w: w, h: h, r: r), mii = boxMean(guide.map { $0 * $0 }, w: w, h: h, r: r)
        var a = [Float](repeating: 0, count: w * h), b = a
        for i in 0..<(w * h) {
            let v = mii[i] - mi[i] * mi[i]
            let c = mip[i] - mi[i] * mp[i]
            a[i] = c / (v + eps)
            b[i] = mp[i] - a[i] * mi[i]
        }
        let ma = boxMean(a, w: w, h: h, r: r), mb = boxMean(b, w: w, h: h, r: r)
        return (0..<(w * h)).map { ma[$0] * guide[$0] + mb[$0] }
    }

    /// Guided filter with a colour guide (He et al. Eq. 19–21: a_k = (Σ_k + εU)⁻¹ cov_k(I, p)).
    public static func guidedFilterColor(_ guide: SegmentRGBImage, _ p: [Float], r: Int, eps: Float, on backend: Backend = .cpu) throws -> [Float] {
        if try Selection.useGPU(backend, guide.w * guide.h) { return try SegmentKit.GPU.guidedFilterColor(guide, p, r: r, eps: eps) }
        return guidedFilterColorCPU(guide, p, r: r, eps: eps)
    }

    static func guidedFilterColorCPU(_ guide: SegmentRGBImage, _ p: [Float], r: Int, eps: Float) -> [Float] {
        let w = guide.w, h = guide.h, n = w * h
        let chans = (0..<3).map { c in guide.px.map { $0[c] } }
        let m = chans.map { boxMean($0, w: w, h: h, r: r) }
        let mp = boxMean(p, w: w, h: h, r: r)
        let mip = chans.map { c in boxMean(zip(c, p).map { $0 * $1 }, w: w, h: h, r: r) }
        let pairs = [(0, 0), (0, 1), (0, 2), (1, 1), (1, 2), (2, 2)]
        let mii = pairs.map { a, b in boxMean(zip(chans[a], chans[b]).map { $0 * $1 }, w: w, h: h, r: r) }
        var a0 = [Float](repeating: 0, count: n), a1 = a0, a2 = a0, bv = a0
        a0.withUnsafeMutableBufferPointer { p0 in
            a1.withUnsafeMutableBufferPointer { p1 in
                a2.withUnsafeMutableBufferPointer { p2 in
                    bv.withUnsafeMutableBufferPointer { pb in
                        let q0 = UnsafeSendable(p0), q1 = UnsafeSendable(p1), q2 = UnsafeSendable(p2), qb = UnsafeSendable(pb)
                        parallelChunks(n, minChunk: 4096) { range in
                            for i in range {
                                let s = SegmentKit.solveGuided(m[0][i], m[1][i], m[2][i], mii[0][i], mii[1][i], mii[2][i], mii[3][i], mii[4][i], mii[5][i],
                                                               mip[0][i], mip[1][i], mip[2][i], mp[i], eps)
                                q0.value[i] = s.0; q1.value[i] = s.1; q2.value[i] = s.2; qb.value[i] = s.3
                            }
                        }
                    }
                }
            }
        }
        let av = [a0, a1, a2]
        let ma = av.map { boxMean($0, w: w, h: h, r: r) }
        let mb = boxMean(bv, w: w, h: h, r: r)
        return (0..<n).map { i in ma[0][i] * chans[0][i] + ma[1][i] * chans[1][i] + ma[2][i] * chans[2][i] + mb[i] }
    }

    /// Separable Gaussian blur, edges clamped (photocraft `matting::gaussian_blur`).
    public static func gaussianBlur(_ src: [Float], w: Int, h: Int, sigma: Float) -> [Float] {
        if sigma < 0.1 { return src }
        let r = Int((sigma * 3).rounded(.up))
        let k0: [Float] = (-r...r).map { expf(Float(-($0 * $0)) / (2 * sigma * sigma)) }
        var s: Float = 0
        for v in k0 { s += v }
        let k = k0.map { $0 / s }
        var tmp = [Float](repeating: 0, count: w * h)
        src.withUnsafeBufferPointer { sb in
            tmp.withUnsafeMutableBufferPointer { tb in
                let t = UnsafeSendable(tb)
                parallelChunks(h, minChunk: 8) { rows in
                    for y in rows {
                        for x in 0..<w {
                            var a: Float = 0
                            for (i, kv) in k.enumerated() { a += sb[y * w + min(max(x + i - r, 0), w - 1)] * kv }
                            t.value[y * w + x] = a
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        tmp.withUnsafeBufferPointer { tb in
            out.withUnsafeMutableBufferPointer { ob in
                let o = UnsafeSendable(ob)
                parallelChunks(h, minChunk: 8) { rows in
                    for y in rows {
                        for x in 0..<w {
                            var a: Float = 0
                            for (i, kv) in k.enumerated() { a += tb[min(max(y + i - r, 0), h - 1) * w + x] * kv }
                            o.value[y * w + x] = a
                        }
                    }
                }
            }
        }
        return out
    }

    /// Per-pixel transition width (pixels) of the guide's luminance: local range / local max
    /// gradient over a window of radius `r` (a sharp step gives ~2, a ramp of width L ~L).
    public static func edgeWidth(_ img: SegmentRGBImage, r: Int) -> [Float] {
        let w = img.w, h = img.h
        let y = img.px.map { 0.299 * $0.x + 0.587 * $0.y + 0.114 * $0.z }
        var g = [Float](repeating: 0, count: w * h)
        for yy in 0..<h {
            for xx in 0..<w {
                let gx = (y[yy * w + min(xx + 1, w - 1)] - y[yy * w + (xx > 0 ? xx - 1 : 0)]) / 2
                let gy = (y[min(yy + 1, h - 1) * w + xx] - y[(yy > 0 ? yy - 1 : 0) * w + xx]) / 2
                g[yy * w + xx] = (gx * gx + gy * gy).squareRoot()
            }
        }
        let gm = maxSquare(g, w, h, r, true), hi = maxSquare(y, w, h, r, true), lo = maxSquare(y, w, h, r, false)
        return (0..<(w * h)).map { (hi[$0] - lo[$0]) / Float.maximum(gm[$0], 1e-4) }
    }

    /// Refines a soft mask buffer `m` (w × h) with `img` as guide (required when radius > 0).
    public static func refineBuffer(_ img: SegmentRGBImage?, _ m: [Float], w: Int, h: Int, _ p: RefineParams) -> [Float] {
        refineBufferWith(img, m, w, h, p, nil)
    }

    /// The Refine Edge Brush over one buffer: signed coverage and the box radius of its estimate.
    struct BrushBuf {
        var v: [Float]
        var window: Int
    }

    static func refineBufferWith(_ img: SegmentRGBImage?, _ m: [Float], _ w: Int, _ h: Int, _ p: RefineParams, _ brush: BrushBuf?) -> [Float] {
        var a = m
        if p.usesImage, let img {
            let bin = m.map { $0 >= 0.5 }
            var boundary = [Bool](repeating: false, count: w * h)
            var any = false
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x, v = bin[i]
                    let diff = (x > 0 && bin[i - 1] != v) || (x + 1 < w && bin[i + 1] != v) || (y > 0 && bin[i - w] != v) || (y + 1 < h && bin[i + w] != v)
                    boundary[i] = diff
                    if diff { any = true }
                }
            }
            if any {
                let dist = (try? Selection.edt(boundary, w: w, h: h, on: .cpu)) ?? []
                let r = p.gfRadius
                let q = guidedFilterColorCPU(img, m, r: r, eps: eps)
                let widths = p.smartRadius ? edgeWidth(img, r: r) : nil
                for i in 0..<(w * h) {
                    let reff = widths.map { clampf($0[i], 1.5, Float.maximum(p.radius, 1.5)) } ?? p.radius
                    var wgt = clampf(reff + 1 - dist[i], 0, 1)
                    // Restored by the brush: the original edge.
                    if let b = brush, i < b.v.count, b.v[i] < 0 { wgt *= 1 + b.v[i] }
                    if wgt > 0 { a[i] = m[i] + (clampf(q[i], 0, 1) - m[i]) * wgt }
                }
            }
        }
        // Added by the brush: coverage estimated from the image.
        if let b = brush, b.v.contains(where: { $0 > 0 }), let img {
            let est = SegmentKit.brushEstimate(img, m, b.v, w, h, b.window)
            for i in 0..<a.count where i < b.v.count && b.v[i] > 0 { a[i] += (est[i] - a[i]) * b.v[i] }
        }
        let ss = p.smoothSigma
        if ss >= 0.3 {
            a = gaussianBlur(a, w: w, h: h, sigma: ss)
            let gain = 1 + ss
            for i in 0..<a.count { a[i] = clampf((a[i] - 0.5) * gain + 0.5, 0, 1) }
        }
        a = gaussianBlur(a, w: w, h: h, sigma: p.featherSigma)
        if p.contrast > 0 {
            let gain = 1 / (1 - 0.99 * clampf(p.contrast, 0, 100) / 100)
            for i in 0..<a.count { a[i] = clampf((a[i] - 0.5) * gain + 0.5, 0, 1) }
        }
        let amount = p.shiftAmount
        if abs(amount) >= 1e-4 { a = SegmentKit.shiftMask(a, w, h, amount) }
        return a
    }

    /// Refines a selection mask. `mask(r)` returns coverage over `r` (row-major); `content` bounds
    /// its non-zero pixels; the result is clipped to `canvas`; `sampler` supplies the guide (read
    /// when radius > 0). Nil when nothing remains selected.
    public static func refineMask(_ sampler: any SegmentSampler, mask: @Sendable (PixelRect) -> [Float], content: PixelRect, canvas: PixelRect,
                                  _ p: RefineParams) -> SelectionRegion? {
        refineMaskWith(sampler, mask, content, canvas, p, nil)
    }

    /// `refineMask` with the Refine Edge Brush: where it adds, coverage comes from the image (the
    /// area can reach beyond the band); where it restores, the original edge stays.
    public static func refineMaskBrushed(_ sampler: any SegmentSampler, mask: @Sendable (PixelRect) -> [Float], content: PixelRect, canvas: PixelRect,
                                         _ p: RefineParams, brush: EdgeBrush?) -> SelectionRegion? {
        refineMaskWith(sampler, mask, content, canvas, p, brush)
    }

    static func refineMaskWith(_ sampler: any SegmentSampler, _ mask: @Sendable (PixelRect) -> [Float], _ content0: PixelRect, _ canvas: PixelRect,
                               _ p: RefineParams, _ brush: EdgeBrush?) -> SelectionRegion? {
        let content = content0.intersect(canvas)
        if content.isEmpty { return nil }
        let bbox = content.outset(by: p.spread).union(brush?.addedBounds ?? .empty).intersect(canvas)
        let halo = p.halo + (brush.map { Int32(clamping: $0.window * 4) } ?? 0)
        let tiles = SegmentKit.tiles(bbox, tile)
        var results = [[UInt8]](repeating: [], count: tiles.count)
        results.withUnsafeMutableBufferPointer { rb in
            let res = UnsafeSendable(rb)
            parallelFor(tiles.count) { k in
                let t = tiles[k]
                let r = t.outset(by: halo).intersect(canvas)
                let m = mask(r)
                let rw = r.width
                let first = m.first ?? 0
                func q(_ v: Float) -> UInt8 { SelectionKit.u8Cast((clampf(v, 0, 1) * 255).rounded()) }
                let cx = Int(t.x0 - r.x0), cy = Int(t.y0 - r.y0), cw = t.width, ch = t.height
                func core(_ buf: [Float]) -> [UInt8] {
                    var out = [UInt8]()
                    out.reserveCapacity(cw * ch)
                    for yy in 0..<ch { for xx in 0..<cw { out.append(q(buf[(cy + yy) * rw + cx + xx])) } }
                    return out
                }
                let painted: [Float]? = brush.flatMap { $0.bounds.intersect(r).isEmpty ? nil : $0.read(r) }
                let adds = painted?.contains(where: { $0 > 0 }) ?? false
                if !adds && (first == 0 || first == 1) && m.allSatisfy({ $0 == first }) {
                    res.value[k] = [UInt8](repeating: q(first), count: cw * ch)
                    return
                }
                let img = p.usesImage || adds ? sampler.rgb(r) : nil
                let bb = painted.flatMap { v in brush.map { BrushBuf(v: v, window: $0.window) } }
                res.value[k] = core(refineBufferWith(img, m, rw, r.height, p, bb))
            }
        }
        let bw = bbox.width
        var out = [UInt8](repeating: 0, count: bw * bbox.height)
        for (t, data) in zip(tiles, results) {
            let cw = t.width
            for yy in 0..<t.height {
                let o = (Int(t.y0 - bbox.y0) + yy) * bw + Int(t.x0 - bbox.x0)
                out.replaceSubrange(o..<(o + cw), with: data[(yy * cw)..<(yy * cw + cw)])
            }
        }
        return QuickSelection.trimRegion(SelectionRegion(bbox: bbox, mask: out))
    }

    /// A mask reader over a region (zero outside its box).
    public static func regionReader(_ reg: SelectionRegion) -> @Sendable (PixelRect) -> [Float] {
        { r in
            var v = [Float]()
            v.reserveCapacity(r.area)
            for y in r.y0..<r.y1 { for x in r.x0..<r.x1 { v.append(reg.at(x, y)) } }
            return v
        }
    }

    /// A mask reader over a selection surface (channel 0).
    public static func surfaceReader(_ s: Surface) -> @Sendable (PixelRect) -> [Float] {
        { r in Selection.maskFromSurface(s, area: r) }
    }

    /// GRAY8 surface (default 0) holding a region's coverage.
    public static func regionSurface(_ reg: SelectionRegion) -> Surface {
        var s = Surface(format: .gray8, rect: reg.bbox, interleaved: reg.mask)
        s.prune()
        return s
    }

    /// Decontaminates colours in the soft fringe of `alpha`: each fringe pixel moves towards the
    /// average colour of nearby fully selected pixels (normalised convolution, box radius
    /// max(radius, 3), ×4 where none is that near), by `amount` % scaled by its transparency. In
    /// the surface's own colour channels (any model / depth).
    public static func decontaminate(_ src: Surface, alpha: SelectionRegion, radius: Float, amount: Float) -> Surface {
        let fmt = src.format
        let n = fmt.channels, nc = n - (fmt.alpha ? 1 : 0)
        let rad = Int(Float.maximum(radius, 3).rounded(.up))
        let halo = Int32(rad * 4)
        let amt = clampf(amount, 0, 100) / 100
        func soft(_ a: Float) -> Bool { a > 0.02 && a < 0.98 }
        let tiles = SegmentKit.tiles(alpha.bbox, tile)
        var results = [(PixelRect, [Float])?](repeating: nil, count: tiles.count)
        results.withUnsafeMutableBufferPointer { rb in
            let res = UnsafeSendable(rb)
            parallelFor(tiles.count) { k in
                let t = tiles[k]
                if !(t.y0..<t.y1).contains(where: { y in (t.x0..<t.x1).contains { x in soft(alpha.at(x, y)) } }) { return }
                let r = t.outset(by: halo)
                let rw = r.width, rh = r.height
                let px = src.readRegion(r)
                var al = [Float](); al.reserveCapacity(rw * rh)
                for y in r.y0..<r.y1 { for x in r.x0..<r.x1 { al.append(alpha.at(x, y)) } }
                let wts: [Float] = (0..<(rw * rh)).map { i in al[i] >= 0.98 ? (fmt.alpha ? px[i * n + n - 1] : 1) : 0 }
                let den = boxMean(wts, w: rw, h: rh, r: rad), den2 = boxMean(wts, w: rw, h: rh, r: rad * 4)
                var nums: [([Float], [Float])] = []
                for c in 0..<nc {
                    let v = (0..<(rw * rh)).map { wts[$0] * px[$0 * n + c] }
                    nums.append((boxMean(v, w: rw, h: rh, r: rad), boxMean(v, w: rw, h: rh, r: rad * 4)))
                }
                let cx = Int(t.x0 - r.x0), cy = Int(t.y0 - r.y0), cw = t.width, ch = t.height
                var out = [Float](); out.reserveCapacity(cw * ch * n)
                for yy in 0..<ch {
                    for xx in 0..<cw {
                        let i = (cy + yy) * rw + cx + xx
                        let a = al[i]
                        let kk: Float = soft(a) ? amt * clampf((1 - a) * 4, 0, 1) : 0
                        for c in 0..<n {
                            let v = px[i * n + c]
                            if c >= nc || kk == 0 { out.append(v); continue }
                            let f: Float = den[i] > 1e-4 ? nums[c].0[i] / den[i] : (den2[i] > 1e-4 ? nums[c].1[i] / den2[i] : v)
                            out.append(v + (f - v) * kk)
                        }
                    }
                }
                res.value[k] = (t, out)
            }
        }
        var out = src
        for case let (t, data)? in results { out.writeRegion(t, data) }
        return out
    }

    /// The pixels of `src` with their alpha multiplied by `alpha` (zero outside its box); the
    /// result has an alpha channel even if `src` does not.
    public static func maskedCopy(_ src: Surface, alpha: SelectionRegion) -> Surface {
        let fmt = src.format
        let n = fmt.channels
        let outFmt = fmt.with(alpha: true)
        let m = outFmt.channels
        let tiles = SegmentKit.tiles(alpha.bbox, tile)
        var results = [(PixelRect, [Float])?](repeating: nil, count: tiles.count)
        results.withUnsafeMutableBufferPointer { rb in
            let res = UnsafeSendable(rb)
            parallelFor(tiles.count) { k in
                let t = tiles[k]
                let px = src.readRegion(t)
                var out = [Float](); out.reserveCapacity(t.area * m)
                var any = false, i = 0
                for y in t.y0..<t.y1 {
                    for x in t.x0..<t.x1 {
                        let a = alpha.at(x, y)
                        out.append(contentsOf: px[(i * n)..<(i * n + m - 1)])
                        let sa: Float = fmt.alpha ? px[i * n + n - 1] : 1
                        out.append(sa * a)
                        if sa * a > 0 { any = true }
                        i += 1
                    }
                }
                if any { res.value[k] = (t, out) }
            }
        }
        var out = Surface(format: outFmt)
        for case let (t, data)? in results { out.writeRegion(t, data) }
        out.prune()
        return out
    }
}

/// Shared helpers of the segment port.
enum SegmentKit {
    /// `area` cut into tiles of `t` px (photocraft `tiles_of`).
    static func tiles(_ area: PixelRect, _ t: Int32) -> [PixelRect] {
        var out: [PixelRect] = []
        var y = area.y0
        while y < area.y1 {
            var x = area.x0
            while x < area.x1 {
                out.append(PixelRect(x0: x, y0: y, x1: min(x + t, area.x1), y1: min(y + t, area.y1)))
                x += t
            }
            y += t
        }
        return out
    }

    /// The colour guided filter's per-pixel solve in Double (photocraft `guided_filter_color`'s
    /// loop body): returns (a0, a1, a2, b).
    @inline(__always)
    static func solveGuided(_ m0: Float, _ m1: Float, _ m2: Float, _ i00: Float, _ i01: Float, _ i02: Float, _ i11: Float, _ i12: Float, _ i22: Float,
                            _ p0: Float, _ p1: Float, _ p2: Float, _ mp: Float, _ eps: Float) -> (Float, Float, Float, Float) {
        let mu = (Double(m0), Double(m1), Double(m2))
        let e = Double(eps)
        let rr = Double(i00) - mu.0 * mu.0 + e, rg = Double(i01) - mu.0 * mu.1, rb = Double(i02) - mu.0 * mu.2
        let gg = Double(i11) - mu.1 * mu.1 + e, gb = Double(i12) - mu.1 * mu.2, bb = Double(i22) - mu.2 * mu.2 + e
        let mpd = Double(mp)
        let cov = (Double(p0) - mu.0 * mpd, Double(p1) - mu.1 * mpd, Double(p2) - mu.2 * mpd)
        // Inverse of the symmetric 3×3 matrix.
        let j00 = gg * bb - gb * gb, j01 = gb * rb - rg * bb, j02 = rg * gb - gg * rb
        let j11 = rr * bb - rb * rb, j12 = rb * rg - rr * gb, j22 = rr * gg - rg * rg
        let det = rr * j00 + rg * j01 + rb * j02
        var a0 = 0.0, a1 = 0.0, a2 = 0.0
        if !(abs(det) < 1e-30) {
            a0 = (j00 * cov.0 + j01 * cov.1 + j02 * cov.2) / det
            a1 = (j01 * cov.0 + j11 * cov.1 + j12 * cov.2) / det
            a2 = (j02 * cov.0 + j12 * cov.1 + j22 * cov.2) / det
        }
        return (Float(a0), Float(a1), Float(a2), Float(mpd - a0 * mu.0 - a1 * mu.1 - a2 * mu.2))
    }

    /// Grow or shrink `src` by a fractional distance: whole pixels by one morphology, the remainder
    /// blending with the next pixel (photocraft `shift_mask`).
    static func shiftMask(_ src: [Float], _ w: Int, _ h: Int, _ amount: Float) -> [Float] {
        let mag = abs(amount)
        if !mag.isFinite || mag < 1e-4 { return src }
        let grow = amount > 0
        let whole = Int(mag.rounded(.down))
        let frac = mag - Float(whole)
        if frac < 1e-4 { return Matting.morph(src, w: w, h: h, r: whole, grow: grow) }
        let lo = whole == 0 ? src : Matting.morph(src, w: w, h: h, r: whole, grow: grow)
        let hi = Matting.morph(src, w: w, h: h, r: whole + 1, grow: grow)
        let n = w * h
        if lo.count < n || hi.count < n || lo.count != hi.count { return hi }
        return zip(lo, hi).map { $0 + ($1 - $0) * frac }
    }
}
