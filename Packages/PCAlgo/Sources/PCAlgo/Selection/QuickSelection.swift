// Port of photocraft-algo (crates/algo/src/segment/quick.rs; segment/mod.rs: RgbImage, Sampler, grid_cut, contrast_beta, trim_region; segment/edge_starts.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Quick Selection brush, behaving like Photoshop's (photocraft measured Photoshop 25.4 as a black
// box): the brush footprint is always selected; beyond it the selection grows to image edges but
// every selected pixel costs a little, so a click takes a whole object only when it is small
// enough for the brush. One min cut (Boykov & Jolly, ICCV 2001) over the working image of
//
//   Σ selected p beyond the footprint  AREA·(1 + DIST·d(p)^POW)  +  Σ cut neighbours  w(|Ip − Iq|)/|p − q|,
//   w(D) = FLOOR + 1/(1 + (D/SIGMA)^K)
//
// with constants fitted to Photoshop's masks; documents above 512 × 512 work at exactly half
// resolution (mask scaled up bilinearly); large windows are cut coarse to fine in a band
// (Lombaert et al., ICCV 2005). The max-flow is sequential (MaxFlow.swift): CPU only; the per-pixel
// preprocessing (distance transform) is the selection EDT.

import Foundation
import PCFoundation

/// Row-major RGB image, samples 0…1 (photocraft `segment::RgbImage`).
public struct SegmentRGBImage: Sendable, Equatable {
    public var w: Int
    public var h: Int
    public var px: [SIMD3<Float>]

    public init(w: Int, h: Int) { self.w = w; self.h = h; px = [SIMD3<Float>](repeating: .zero, count: w * h) }
    public init(w: Int, h: Int, px: [SIMD3<Float>]) { self.w = w; self.h = h; self.px = px }
    public init(w: Int, h: Int, _ f: (Int, Int) -> SIMD3<Float>) {
        self.w = w; self.h = h
        px = []
        px.reserveCapacity(w * h)
        for y in 0..<h { for x in 0..<w { px.append(f(x, y)) } }
    }

    @inline(__always) public func at(_ x: Int, _ y: Int) -> SIMD3<Float> { px[y * w + x] }

    /// Straight RGBA to RGB, compositing transparent pixels over mid grey.
    public static func fromRGBA(_ px: [SIMD4<Float>], w: Int, h: Int) -> SegmentRGBImage {
        SegmentRGBImage(w: w, h: h, px: px.map { p in
            let a = clampf(p.w, 0, 1)
            return SIMD3(clampf(p.x, 0, 1) * a + 0.5 * (1 - a), clampf(p.y, 0, 1) * a + 0.5 * (1 - a), clampf(p.z, 0, 1) * a + 0.5 * (1 - a))
        })
    }

    /// Box-average downsampling by an integer `step` (output ⌈w/step⌉ × ⌈h/step⌉).
    public func downsample(_ step: Int) -> SegmentRGBImage {
        if step <= 1 { return self }
        let ow = (w + step - 1) / step, oh = (h + step - 1) / step
        var out = SegmentRGBImage(w: ow, h: oh)
        for oy in 0..<oh {
            for ox in 0..<ow {
                var acc = SIMD3<Float>(0, 0, 0)
                var n: Float = 0
                for y in (oy * step)..<min((oy + 1) * step, h) {
                    for x in (ox * step)..<min((ox + 1) * step, w) {
                        let p = at(x, y)
                        acc.x += p.x; acc.y += p.y; acc.z += p.z
                        n += 1
                    }
                }
                out.px[oy * ow + ox] = SIMD3(acc.x / n, acc.y / n, acc.z / n)
            }
        }
        return out
    }
}

/// Where the segmentation reads colours from (a layer, the composite, a test image) —
/// photocraft `segment::Sampler`.
public protocol SegmentSampler: Sendable {
    /// Straight RGBA (0…1) over `r` (document pixels), row-major.
    func rgba(_ r: PixelRect) -> [SIMD4<Float>]
}

extension SegmentSampler {
    /// RGB over `r` at full resolution.
    public func rgb(_ r: PixelRect) -> SegmentRGBImage { SegmentRGBImage.fromRGBA(rgba(r), w: r.width, h: r.height) }

    /// RGB over `r`, box-downsampled by `step`, read in horizontal strips (in parallel) so the
    /// full-resolution area is never held at once.
    public func rgbScaled(_ r: PixelRect, step: Int) -> SegmentRGBImage {
        if step <= 1 { return rgb(r) }
        let w = r.width, h = r.height
        let ow = (w + step - 1) / step, oh = (h + step - 1) / step
        let rowsPer = max((64 + step - 1) / step, 1)
        let strips = (oh + rowsPer - 1) / rowsPer
        var parts = [[SIMD3<Float>]](repeating: [], count: strips)
        parts.withUnsafeMutableBufferPointer { pb in
            let p = UnsafeSendable(pb)
            parallelFor(strips) { si in
                let oy0 = si * rowsPer, oy1 = min(oy0 + rowsPer, oh)
                let y0 = r.y0 + Int32(oy0 * step), y1 = min(r.y0 + Int32(oy1 * step), r.y1)
                p.value[si] = rgb(PixelRect(x0: r.x0, y0: y0, x1: r.x1, y1: y1)).downsample(step).px
            }
        }
        return SegmentRGBImage(w: ow, h: oh, px: parts.flatMap { $0 })
    }
}

/// Samples a raster surface (any format; converted to straight RGBA).
public struct SurfaceSegmentSampler: SegmentSampler {
    public let surface: Surface
    public init(_ surface: Surface) { self.surface = surface }
    public func rgba(_ r: PixelRect) -> [SIMD4<Float>] { r.isEmpty ? [] : surface.readRGBA(r) }
}

/// Samples an in-memory RGB image placed at `origin` (tests, benchmarks); transparent outside.
public struct ImageSegmentSampler: SegmentSampler {
    public let img: SegmentRGBImage
    public let origin: (Int32, Int32)
    public init(_ img: SegmentRGBImage, origin: (Int32, Int32) = (0, 0)) { self.img = img; self.origin = origin }
    public func rgba(_ r: PixelRect) -> [SIMD4<Float>] {
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(r.area)
        for y in r.y0..<r.y1 {
            for x in r.x0..<r.x1 {
                let ix = Int(x) - Int(origin.0), iy = Int(y) - Int(origin.1)
                if ix < 0 || iy < 0 || ix >= img.w || iy >= img.h { out.append(.zero) } else { out.append(SIMD4(img.at(ix, iy), 1)) }
            }
        }
        return out
    }
}

/// The graph cut and Quick Selection (photocraft `segment` / `segment::quick`).
public enum QuickSelection {
    /// Pixel label constraints for `gridCut`.
    public static let free: UInt8 = 0
    public static let hardFG: UInt8 = 1
    public static let hardBG: UInt8 = 2

    /// The 4 forward neighbour offsets of an 8-connected grid and their lengths.
    static let nb: [(Int, Int, Float)] = [(1, 0, 1), (0, 1, 1), (1, 1, 1.41421356237309504880), (-1, 1, 1.41421356237309504880)]

    @inline(__always)
    static func d2(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let x = a.x - b.x, y = a.y - b.y, z = a.z - b.z
        return x * x + y * y + z * z
    }

    /// GrabCut's contrast parameter β = 1 / (2⟨‖z_m − z_n‖²⟩) over 8-neighbour pairs.
    public static func contrastBeta(_ img: SegmentRGBImage) -> Float {
        let w = img.w, h = img.h
        var sum = 0.0
        var n: UInt64 = 0
        for y in 0..<h {
            for x in 0..<w {
                let a = img.px[y * w + x]
                for (dx, dy, _) in nb {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0 && nx < w && ny < h { sum += Double(d2(a, img.px[ny * w + nx])); n += 1 }
                }
            }
        }
        return n == 0 || sum <= 1e-12 ? 0 : Float(Double(n) / (2 * sum))
    }

    /// Binary labelling of a grid by one min cut (Boykov & Jolly 2001): minimises
    /// Σ D_p(l_p) + Σ_{p~q} [l_p ≠ l_q] γ e^{−β‖z_p−z_q‖²}/dist(p,q) over the 8-connected grid.
    /// `fixed[i]` is free / hardFG / hardBG; returns true for foreground.
    public static func gridCut(_ img: SegmentRGBImage, costFG: [Float], costBG: [Float], fixed: [UInt8], gamma: Float, beta: Float) -> [Bool] {
        gridCutWeighted(img, costFG, costBG, fixed, optimized: true) { gamma * expf(-beta * $0) }
    }

    /// `gridCut` with any edge weight: separating neighbours costs weight(‖z_p−z_q‖²)/dist(p,q).
    public static func gridCutWith(_ img: SegmentRGBImage, costFG: [Float], costBG: [Float], fixed: [UInt8], weight: (Float) -> Float) -> [Bool] {
        gridCutWeighted(img, costFG, costBG, fixed, optimized: true, weight)
    }

    /// photocraft `grid_cut_weighted` (`optimized`: only links touching a free pixel get weights,
    /// sparse traversal when few pixels are free; the dense raster otherwise).
    static func gridCutWeighted(_ img: SegmentRGBImage, _ costFG: [Float], _ costBG: [Float], _ fixed: [UInt8], optimized: Bool,
                                _ weight: (Float) -> Float) -> [Bool] {
        let (n, ovf) = img.w.multipliedReportingOverflow(by: img.h)
        if ovf || n >= Int(UInt32.max) - 2 { return [] }
        if img.w > Int(Int32.max) || img.h > Int(Int32.max) || [img.px.count, costFG.count, costBG.count, fixed.count].contains(where: { $0 < n }) { return [] }
        let w = img.w, h = img.h
        var idx = [UInt32](repeating: UInt32.max, count: n)
        var count: UInt32 = 0
        for i in 0..<n where fixed[i] == free { idx[i] = count; count += 1 }
        var out = fixed.map { $0 == hardFG }
        if count == 0 { return out }
        var g = SelectionKit.MaxFlowGraph(nodes: Int(count), edges: Int(count) * 4)
        for i in 0..<n where idx[i] != UInt32.max { g.addTWeights(Int(idx[i]), costBG[i], costFG[i]) }
        let useSparse = optimized && Int(count) < n / 8
        func addFixedLink(_ node: Int, _ f: UInt8, _ wt: Float) {
            if f == hardFG { g.addTWeights(node, wt, 0) } else { g.addTWeights(node, 0, wt) }
        }
        func visit(_ i: Int, _ x: Int, _ y: Int) {
            let a = img.px[i]
            for (dx, dy, len) in nb {
                let nx = x + dx, ny = y + dy
                if nx < 0 || nx >= w || ny >= h { continue }
                let j = ny * w + nx
                if optimized && idx[i] == UInt32.max && idx[j] == UInt32.max { continue }
                let wt = weight(d2(a, img.px[j])) / len
                switch (idx[i] != UInt32.max, idx[j] != UInt32.max) {
                case (true, true): g.addEdge(Int(idx[i]), Int(idx[j]), wt, wt)
                case (true, false): addFixedLink(Int(idx[i]), fixed[j], wt)
                case (false, true): addFixedLink(Int(idx[j]), fixed[i], wt)
                case (false, false): break
                }
            }
        }
        if useSparse {
            let freeList = (0..<n).filter { idx[$0] != UInt32.max }
            var starts = EdgeStarts(freeList, w)
            while let i = starts.next() { visit(i, i % w, i / w) }
        } else {
            // The original dense raster traversal, including its arithmetic order.
            for y in 0..<h { for x in 0..<w { visit(y * w + x, x, y) } }
        }
        if optimized { g.maxflow() } else { g.maxflowBK() }
        for i in 0..<n where idx[i] != UInt32.max { out[i] = g.inSource(Int(idx[i])) }
        return out
    }

    /// Source pixels of canonical grid links touching a free pixel, in raster order: a five-way
    /// merge of the free pixels and their left/upper three predecessors (photocraft `Starts`).
    struct EdgeStarts {
        let free: [Int]
        let w: Int
        var at = [Int](repeating: 0, count: 5)
        var peek = [Int?](repeating: nil, count: 5)

        init(_ free: [Int], _ w: Int) {
            self.free = free; self.w = w
            for k in 0..<5 { advance(k) }
        }

        mutating func advance(_ k: Int) {
            peek[k] = nil
            while at[k] < free.count {
                let i = free[at[k]]
                at[k] += 1
                let x = i % w
                let value: Int?
                switch k {
                case 0: value = i
                case 1: value = x > 0 ? i - 1 : nil
                case 2: value = i >= w ? i - w : nil
                case 3: value = i >= w && x > 0 ? i - w - 1 : nil
                default: value = i >= w && x + 1 < w ? i - w + 1 : nil
                }
                if let v = value { peek[k] = v; break }
            }
        }

        mutating func next() -> Int? {
            guard let first = peek.compactMap({ $0 }).min() else { return nil }
            for k in 0..<5 where peek[k] == first { advance(k) }
            return first
        }
    }

    /// Shrinks a region's box to its non-zero pixels (nil if empty) — photocraft `trim_region`.
    public static func trimRegion(_ r: SelectionRegion) -> SelectionRegion? {
        let w = r.bbox.width
        if w == 0 { return nil }
        let h = r.mask.count / w
        var x0 = Int.max, y0 = Int.max, x1 = 0, y1 = 0
        for y in 0..<h {
            let row = r.mask[(y * w)..<(y * w + w)]
            if let a = row.firstIndex(where: { $0 != 0 }), let b = row.lastIndex(where: { $0 != 0 }) {
                x0 = min(x0, a - y * w); x1 = max(x1, b - y * w + 1); y0 = min(y0, y); y1 = y + 1
            }
        }
        if x0 == Int.max { return nil }
        if (x0, y0, x1, y1) == (0, 0, w, h) { return r }
        var mask: [UInt8] = []
        mask.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { mask.append(contentsOf: r.mask[(y * w + x0)..<(y * w + x1)]) }
        let b = r.bbox
        return SelectionRegion(bbox: PixelRect(x0: b.x0 + Int32(x0), y0: b.y0 + Int32(y0), x1: b.x0 + Int32(x1), y1: b.y0 + Int32(y1)), mask: mask)
    }

    // MARK: Quick Selection

    /// The model's constants (photocraft `quick::Tuning`); the defaults are the fit to Photoshop.
    public struct Tuning: Sendable, Hashable {
        /// Cost of each selected pixel beyond the footprint, × (1 + dist·d^pow), d its distance
        /// from the footprint (working pixels).
        public var area: Float = 0.004079
        public var dist: Float = 0.002651
        public var pow: Float = 0.98885
        /// Cut weight between neighbours: floor + 1/(1 + (|Ip − Iq|/sigma)^k) (RGB 0…1).
        public var floor: Float = 0.018847
        public var sigma: Float = 0.048450
        public var k: Float = 1.98549
        /// The footprint grows by grow + growFrac·radius working pixels (Photoshop's settled click).
        public var grow: Float = 1.69371
        public var growFrac: Float = 0.103003
        /// Larger working windows are cut coarse to fine.
        public var directPx: Int = 300_000
        public init() {}
    }

    /// The working step for a w × h document: the whole document up to 512 × 512, half above.
    public static func workingStep(_ w: Int, _ h: Int) -> Int {
        let (p, o) = w.multipliedReportingOverflow(by: h)
        return !o && p <= 512 * 512 ? 1 : 2
    }

    /// Grows a selection from a brush stroke (`points` in document pixels, brush diameter `size`)
    /// on the document `canvas`: the new region (to add to or subtract from the current
    /// selection), or nil when the stroke misses the canvas.
    public static func quickSelect(_ sampler: any SegmentSampler, canvas: PixelRect, points: [SIMD2<Float>], size: Float,
                                   tuning t: Tuning = Tuning()) -> SelectionRegion? {
        if points.isEmpty || canvas.isEmpty { return nil }
        let r = Float.maximum(size, 1) / 2
        var x0 = Float.greatestFiniteMagnitude, y0 = Float.greatestFiniteMagnitude, x1 = -Float.greatestFiniteMagnitude, y1 = -Float.greatestFiniteMagnitude
        for p in points {
            x0 = Float.minimum(x0, p.x - r); y0 = Float.minimum(y0, p.y - r)
            x1 = Float.maximum(x1, p.x + r); y1 = Float.maximum(y1, p.y + r)
        }
        func clampI(_ v: Float) -> Int32 { SelectionKit.i32Cast(clampf(v, Float(Int32.min) / 2, Float(Int32.max) / 2)) }
        let bbox = PixelRect(x0: clampI(x0.rounded(.down)), y0: clampI(y0.rounded(.down)),
                             x1: clampI(x1.rounded(.up)) &+ 1, y1: clampI(y1.rounded(.up)) &+ 1).intersect(canvas)
        if bbox.isEmpty { return nil }
        let step = Int32(workingStep(canvas.width, canvas.height))
        let rw = r / Float(step)
        // Work in a window around the stroke; grow it while the selection runs into its border.
        var margin = SelectionKit.i32Cast(Float.maximum(48, 2 * rw)) &* step
        while true {
            func snap0(_ v: Int32, _ o: Int32) -> Int32 {
                let d = v - o
                let q = d >= 0 ? d / step : -((-d + step - 1) / step)
                return o + q * step
            }
            let grown = bbox.outset(by: margin).intersect(canvas)
            let window = PixelRect(x0: snap0(grown.x0, canvas.x0), y0: snap0(grown.y0, canvas.y0), x1: grown.x1, y1: grown.y1)
            let img = sampler.rgbScaled(window, step: Int(step))
            let lw = img.w, lh = img.h
            let s = Float(step)
            let pts = points.map { SIMD2(($0.x - Float(window.x0)) / s, ($0.y - Float(window.y0)) / s) }
            let seeds = strokeMask(pts, radius: Float.maximum(rw, 0.5), w: lw, h: lh)
            if !seeds.contains(true) { return nil }
            // The window's sides are free like the canvas' edges: a selection clear of them is the
            // best over the whole canvas too; one reaching a side inside the canvas is redone larger.
            let inner = [window.x0 > canvas.x0, window.y0 > canvas.y0, window.x1 < canvas.x1, window.y1 < canvas.y1]
            let low = selectWorking(img, seeds: seeds, radius: rw, tuning: t)
            func touches(_ side: Int) -> Bool {
                switch side {
                case 0: return (0..<lh).contains { low[$0 * lw] }
                case 1: return (0..<lw).contains { low[$0] }
                case 2: return (0..<lh).contains { low[$0 * lw + lw - 1] }
                default: return (0..<lw).contains { low[(lh - 1) * lw + $0] }
                }
            }
            if (0..<4).contains(where: { inner[$0] && touches($0) }) {
                margin = margin.multipliedReportingOverflow(by: 2).overflow ? Int32.max : margin * 2
                continue
            }
            let mask = upsample(low, lw: lw, lh: lh, step: Int(step), w: window.width, h: window.height)
            return trimRegion(SelectionRegion(bbox: window, mask: mask))
        }
    }

    /// The model at working resolution: `seeds` (the brush footprint, `radius` working pixels) are
    /// selected; returns the selection.
    public static func selectWorking(_ img: SegmentRGBImage, seeds: [Bool], radius: Float, tuning t: Tuning = Tuning()) -> [Bool] {
        let w = img.w, h = img.h
        let d = (try? Selection.edt(seeds, w: w, h: h, on: .cpu)) ?? []
        let grow = Float.maximum(t.grow + t.growFrac * radius, 0)
        let costFG = d.map { t.area * (1 + t.dist * powf(Float.maximum($0 - grow, 0), t.pow)) }
        let fixed = d.map { $0 <= grow ? hardFG : free }
        let floor = t.floor, sigma = Float.maximum(t.sigma, 1e-4), k = t.k
        let weight = { (d2: Float) -> Float in floor + 1 / (1 + powf(d2.squareRoot() / sigma, k)) }
        return cutLevels(img, fixed, costFG, weight, 1, max(t.directPx, 1024))
    }

    /// Band half-width (pixels) re-cut at each finer level.
    static let band: Float = 3

    /// Min cut with only foreground costs, coarse to fine above `directPx` pixels (photocraft
    /// `cut_levels`): the half-size problem gives a boundary, and the full-size cut is redone only
    /// within `band` of it.
    static func cutLevels(_ img: SegmentRGBImage, _ fixed: [UInt8], _ costFG: [Float], _ weight: (Float) -> Float, _ scale: Float, _ directPx: Int) -> [Bool] {
        let w = img.w, h = img.h
        let zeros = [Float](repeating: 0, count: w * h)
        if w * h <= directPx || w < 8 || h < 8 {
            return gridCutWeighted(img, costFG, zeros, fixed, optimized: true) { scale * weight($0) }
        }
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        let coarseImg = img.downsample(2)
        var cfix = [UInt8](repeating: free, count: cw * ch)
        var ccost = [Float](repeating: 0, count: cw * ch)
        for y in 0..<h {
            for x in 0..<w {
                let c = (y / 2) * cw + x / 2
                ccost[c] += costFG[y * w + x]
                if fixed[y * w + x] == hardFG { cfix[c] = hardFG }
            }
        }
        let coarse = cutLevels(coarseImg, cfix, ccost, weight, scale * 2, directPx)
        let proj = (0..<(w * h)).map { coarse[($0 / w / 2) * cw + ($0 % w) / 2] }
        // Band: within `band` of the projected boundary.
        let edge: [Bool] = (0..<(w * h)).map { i in
            let x = i % w, y = i / w, v = proj[i]
            return (x > 0 && proj[i - 1] != v) || (x + 1 < w && proj[i + 1] != v) || (y > 0 && proj[i - w] != v) || (y + 1 < h && proj[i + w] != v)
        }
        if !edge.contains(true) { return (0..<(w * h)).map { proj[$0] || fixed[$0] == hardFG } }
        let near = (try? Selection.edt(edge, w: w, h: h, on: .cpu)) ?? []
        let banded: [UInt8] = (0..<(w * h)).map { i in
            if fixed[i] == hardFG { return hardFG }
            if near[i] <= band { return free }
            return proj[i] ? hardFG : hardBG
        }
        return gridCutWeighted(img, costFG, zeros, banded, optimized: true) { scale * weight($0) }
    }

    /// Pixels within `radius` (working pixels) of the polyline `pts`, plus each point's own pixel.
    public static func strokeMask(_ pts: [SIMD2<Float>], radius: Float, w: Int, h: Int) -> [Bool] {
        var m = [Bool](repeating: false, count: w * h)
        let segs: [(SIMD2<Float>, SIMD2<Float>)] = pts.count == 1 ? [(pts[0], pts[0])] : (0..<max(pts.count - 1, 0)).map { (pts[$0], pts[$0 + 1]) }
        for (a, b) in segs {
            let x0 = SelectionKit.usizeCast(Float.maximum((Float.minimum(a.x, b.x) - radius).rounded(.down), 0))
            let y0 = SelectionKit.usizeCast(Float.maximum((Float.minimum(a.y, b.y) - radius).rounded(.down), 0))
            let x1 = min(SelectionKit.usizeCast(Float.maximum((Float.maximum(a.x, b.x) + radius).rounded(.up), 0)), w)
            let y1 = min(SelectionKit.usizeCast(Float.maximum((Float.maximum(a.y, b.y) + radius).rounded(.up), 0)), h)
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            if y0 >= y1 || x0 >= x1 { continue }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let px = Float(x) + 0.5, py = Float(y) + 0.5
                    let t: Float = len2 > 0 ? clampf(((px - a.x) * dx + (py - a.y) * dy) / len2, 0, 1) : 0
                    let qx = a.x + t * dx - px, qy = a.y + t * dy - py
                    if qx * qx + qy * qy <= radius * radius { m[y * w + x] = true }
                }
            }
        }
        for p in pts where p.x >= 0 && p.y >= 0 {
            let x = SelectionKit.usizeCast(p.x), y = SelectionKit.usizeCast(p.y)
            if x < w && y < h { m[y * w + x] = true }
        }
        return m
    }

    /// Bilinear upsampling (pixel centres aligned, edges clamped) of a working-resolution
    /// selection to 8-bit coverage, as Photoshop scales its half-resolution result.
    public static func upsample(_ low: [Bool], lw: Int, lh: Int, step: Int, w: Int, h: Int) -> [UInt8] {
        if step == 1 { return low.map { $0 ? 255 : 0 } }
        @inline(__always) func at(_ x: Int, _ y: Int) -> Float { low[min(max(y, 0), lh - 1) * lw + min(max(x, 0), lw - 1)] ? 1 : 0 }
        let s = Float(step)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let fy = (Float(y) + 0.5) / s - 0.5
            let iy = Int(fy.rounded(.down)), ty = fy - fy.rounded(.down)
            for x in 0..<w {
                let fx = (Float(x) + 0.5) / s - 0.5
                let ix = Int(fx.rounded(.down)), tx = fx - fx.rounded(.down)
                let v = (at(ix, iy) * (1 - tx) + at(ix + 1, iy) * tx) * (1 - ty) + (at(ix, iy + 1) * (1 - tx) + at(ix + 1, iy + 1) * tx) * ty
                out[y * w + x] = SelectionKit.u8Cast((v * 255).rounded())
            }
        }
        return out
    }
}
