// Port of photocraft-algo (crates/algo/src/inpaint.rs: best_offset, synthesize, min_cut; inpaint/proximity_integral.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Proximity match (an automatic Healing Brush source): the displacement whose surrounding ring best
// matches the ring around the hole by sum of squared differences, searched on a coarse grid and
// refined at full resolution around the winner. Create Texture: patch-based synthesis after
// Efros & Freeman, Image Quilting, SIGGRAPH 2001 (blocks picked from random candidates by overlap
// error, joined along minimum-error boundary cuts).
//
// GPU: the SSD scan of every candidate displacement is one thread per displacement (sums in the
// CPU's order; the nearness penalty from the CPU), the winner picked on the CPU in scan order —
// the same offset as the reference, whose early-outs only skip displacements that can't win.

import Foundation
import Metal
import PCFoundation

extension InpaintKit {
    /// Summed-area table restricted to the bounds of a healing hole (photocraft `HoleIntegral`).
    struct HoleIntegral {
        let x0: Int32, y0: Int32
        let w: Int, h: Int
        let data: [UInt32]

        init?(_ stride: Int, _ hole: [Bool], _ b: (Int, Int, Int, Int)) {
            let (bx0, by0, bx1, by1) = b
            guard bx1 >= bx0, by1 >= by0 else { return nil }
            let (w, h) = (bx1 - bx0, by1 - by0)
            let (rs, o1) = w.addingReportingOverflow(1)
            let (hh, o2) = h.addingReportingOverflow(1)
            guard !o1, !o2 else { return nil }
            let (len, o3) = rs.multipliedReportingOverflow(by: hh)
            guard !o3, len < 1 << 40 else { return nil }
            var data = [UInt32](repeating: 0, count: len)
            for (y, sy) in (by0..<by1).enumerated() {
                let base = sy * stride
                guard base + bx1 <= hole.count else { return nil }
                var count: UInt32 = 0
                for x in 0..<w {
                    count += hole[base + bx0 + x] ? 1 : 0
                    data[(y + 1) * rs + x + 1] = data[y * rs + x + 1] + count
                }
            }
            guard bx0 <= Int(Int32.max), by0 <= Int(Int32.max) else { return nil }
            x0 = Int32(bx0); y0 = Int32(by0); self.w = w; self.h = h; self.data = data
        }

        func count(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> UInt32 {
            windowCount(data, w, h, x0.subtractingSaturating(self.x0), y0.subtractingSaturating(self.y0),
                        x1.subtractingSaturating(self.x0), y1.subtractingSaturating(self.y0))
        }
    }

    /// Proximity match: the displacement `(dx, dy)` (within `maxRadius`) whose surroundings best
    /// match the ring of `ring` pixels around the hole, with the displaced hole fully inside the
    /// grid and outside the hole; nil if none fits (photocraft `best_offset`).
    public static func bestOffset(width w: Int, height h: Int, channels ch: Int, image img: [Float], hole: [Bool], ring: Int,
                                  maxRadius: Int32, on backend: Backend = .cpu) throws -> (Int32, Int32)? {
        guard let (bx0, by0, bx1, by1) = holeBBox(w, h, hole) else { return nil }
        // No valid translation can move farther than the image's extent.
        let extent = Int32(min(max(w, h), Int(Int32.max / 4)))
        let maxRadius = min(max(maxRadius, 0), extent)
        if maxRadius == 0 { return nil }
        let ring = Int32(min(max(ring, 1), Int(extent)))
        guard let hs = HoleIntegral(w, hole, (bx0, by0, bx1, by1)) else { return nil }
        // Sample points: the hole's ring (dilated minus hole), subsampled.
        var all: [SIMD2<Int32>] = []
        let (x0, y0) = (Int32(bx0) - ring, Int32(by0) - ring)
        let (x1, y1) = (Int32(bx1) + ring, Int32(by1) + ring)
        var y = max(y0, 0)
        while y < min(y1, Int32(h)) {
            var x = max(x0, 0)
            while x < min(x1, Int32(w)) {
                if !hole[Int(y) * w + Int(x)] && hs.count(x - ring, y - ring, x + ring + 1, y + ring + 1) > 0 { all.append(SIMD2(x, y)) }
                x += 1
            }
            y += 1
        }
        let stride = max(all.count / 2000, 1)
        var pts: [SIMD2<Int32>] = []
        pts.reserveCapacity(all.count / stride + 1)
        var k = 0
        while k < all.count { pts.append(all[k]); k += stride }
        let n = Float(max(pts.count, 1))
        @inline(__always) func penalty(_ dx: Int32, _ dy: Int32) -> Float {
            1 + 1e-3 * (hypotf(Float(dx), Float(dy)) / Float(maxRadius))
        }
        @inline(__always) func fits(_ dx: Int32, _ dy: Int32) -> Bool {
            let (hx0, hy0, hx1, hy1) = (x0 + dx, y0 + dy, x1 + dx, y1 + dy)
            let inside = hx0 >= 0 && hy0 >= 0 && hx1 <= Int32(w) && hy1 <= Int32(h)
            return (dx != 0 || dy != 0) && inside && hs.count(hx0, hy0, hx1, hy1) == 0
        }
        let useGPU: Bool
        switch backend {
        case .cpu: useGPU = false
        case .gpu: useGPU = true
        case .auto: useGPU = AlgoGPU.isAvailable && pts.count * ch >= 256
        }
        // The scores of a list of displacements (skipping those that don't fit), CPU with
        // photocraft's early out against the best so far, or all on the GPU. The first fitting
        // displacement is adopted whatever its score (NaN included), later ones only when lower.
        var hasBest = false
        var bestD = SIMD2<Int32>.zero
        var bestE: Float = .infinity
        func scan(_ cands: [SIMD2<Int32>]) throws {
            if useGPU {
                var fitting: [SIMD2<Int32>] = []
                var pens: [Float] = []
                for c in cands where fits(c.x, c.y) { fitting.append(c); pens.append(penalty(c.x, c.y)) }
                let scores = try proximityGPU(w, ch, img, pts, fitting, pens)
                var i = 0
                while i < fitting.count {
                    if !hasBest || scores[i] < bestE { hasBest = true; bestD = fitting[i]; bestE = scores[i] }
                    i += 1
                }
                return
            }
            img.withUnsafeBufferPointer { ib in
                pts.withUnsafeBufferPointer { pb in
                    let im = ib.baseAddress!, pp = pb.baseAddress!
                    let np = pb.count
                    var ci = 0
                    while ci < cands.count {
                        let (dx, dy) = (cands[ci].x, cands[ci].y)
                        ci += 1
                        if !fits(dx, dy) { continue }
                        let cutoff = hasBest ? bestE : .infinity
                        let pen = penalty(dx, dy)
                        let off = (Int(dy) * w + Int(dx)) * ch
                        var e: Float = 0
                        var gaveUp = false
                        var i = 0
                        while i < np {
                            let a = (Int(pp[i].y) * w + Int(pp[i].x)) * ch, b = a + off
                            var c = 0
                            while c < ch { let d = im[a + c] - im[b + c]; e += d * d; c += 1 }
                            // The partial score is a lower bound on the final one.
                            if i % 32 == 31 && cutoff.isFinite && e / n * pen >= cutoff { gaveUp = true; break }
                            i += 1
                        }
                        if gaveUp { continue }
                        let score = e / n * pen
                        if !hasBest || score < bestE { hasBest = true; bestD = SIMD2(dx, dy); bestE = score }
                    }
                }
            }
        }
        // Coarse grid over the search window, then a full-resolution refinement around the winner.
        let step = max(maxRadius / 24, 1)
        var coarse: [SIMD2<Int32>] = []
        var dy = -maxRadius
        while dy <= maxRadius {
            var dx = -maxRadius
            while dx <= maxRadius { coarse.append(SIMD2(dx, dy)); dx += step }
            dy += step
        }
        try scan(coarse)
        if step > 1 && hasBest {
            let (bx, by) = (bestD.x, bestD.y)
            var fine: [SIMD2<Int32>] = []
            var fy = by - step
            while fy <= by + step {
                var fx = bx - step
                while fx <= bx + step { fine.append(SIMD2(fx, fy)); fx += 1 }
                fy += 1
            }
            try scan(fine)
        }
        return hasBest ? (bestD.x, bestD.y) : nil
    }

    /// The proximity scores of `cands` (all fitting) on the GPU: `e / n · penalty`.
    static func proximityGPU(_ w: Int, _ ch: Int, _ img: [Float], _ pts: [SIMD2<Int32>], _ cands: [SIMD2<Int32>], _ pen: [Float]) throws -> [Float] {
        if cands.isEmpty { return [] }
        let g = try AlgoGPU.shared()
        let dev = g.device
        guard let ib = img.withUnsafeBytes({ dev.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared) }),
              let pb = pts.isEmpty ? dev.makeBuffer(length: 16, options: .storageModeShared)
                : pts.withUnsafeBytes({ dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let cb = cands.withUnsafeBytes({ dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let pnb = pen.withUnsafeBytes({ dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let ob = dev.makeBuffer(length: cands.count * 4, options: .storageModeShared) else {
            throw FilterError.gpuUnavailable("proximity buffers")
        }
        let p = ProximityParams(width: Int32(w), ch: Int32(ch), pts: Int32(pts.count), cands: Int32(cands.count))
        try g.metal.run(label: "Proximity Match") { cmd in
            let pass = try GPUPass.synthetic(g, cmd, rect: PixelRect(x0: 0, y0: 0, x1: Int32(cands.count), y1: 1))
            try pass.dispatch("pca_inp_proximity", params: p, textures: [], buffers: [ib, pb, cb, pnb, ob],
                              width: cands.count, height: 1, threadgroup: (64, 1))
        }
        return Array(UnsafeBufferPointer(start: ob.contents().assumingMemoryBound(to: Float.self), count: cands.count))
    }

    /// MSL `pca_inp_proximity_params`.
    struct ProximityParams: BitwiseCopyable {
        var width: Int32, ch: Int32, pts: Int32, cands: Int32
    }

    // MARK: Create Texture

    /// Create Texture: fill the hole with blocks of surrounding texture (photocraft `synthesize`).
    public static func synthesize(width w: Int, height h: Int, channels ch: Int, image img: [Float], hole: [Bool], block: Int, seed: UInt64) -> [Float] {
        var out = img
        guard let (bx0, by0, bx1, by1) = holeBBox(w, h, hole) else { return out }
        let b = Int32(max(block, 4))
        let ov = max(b / 3, 1)
        let hs = integral(w, h, hole)
        // Candidate block origins: whole block (with overlap) inside the grid and outside the hole.
        var cands: [(Int32, Int32)] = []
        if Int32(h) - b - ov > ov && Int32(w) - b - ov > ov {
            for y in ov..<(Int32(h) - b - ov) {
                for x in ov..<(Int32(w) - b - ov) where windowCount(hs, w, h, x - ov, y - ov, x + b + ov, y + b + ov) == 0 {
                    cands.append((x, y))
                }
            }
        }
        if cands.isEmpty { return Poisson.membraneFill(width: w, height: h, channels: ch, image: img, hole: hole) }
        var filled = hole.map { !$0 }
        var rng = Rng(seed)
        var by = Int32(by0)
        while by < Int32(by1) {
            var bx = Int32(bx0)
            while bx < Int32(bx1) {
                if windowCount(hs, w, h, bx, by, bx + b, by + b) > 0 {
                    // Pick the candidate whose block best agrees with already-known pixels around/inside.
                    var best = (cands[0], Float.infinity)
                    for _ in 0..<48 {
                        let c = cands[Int(rng.next() % UInt64(cands.count))]
                        var e: Float = 0
                        var n: UInt32 = 0
                        for y in (by - ov)..<(by + b + ov) {
                            for x in (bx - ov)..<(bx + b + ov) {
                                if x < 0 || y < 0 || x >= Int32(w) || y >= Int32(h) || !filled[Int(y) * w + Int(x)] { continue }
                                let a = (Int(y) * w + Int(x)) * ch, s = (Int(y - by + c.1) * w + Int(x - bx + c.0)) * ch
                                for k in 0..<ch {
                                    let d = out[a + k] - img[s + k]
                                    e += d * d
                                }
                                n += 1
                            }
                        }
                        let ee: Float = n == 0 ? 0 : e / Float(n)
                        if ee < best.1 { best = (c, ee) }
                    }
                    let c = best.0
                    let (x0, y0) = (max(bx - ov, 0), max(by - ov, 0))
                    let (x1, y1) = (min(bx + b + ov, Int32(w)), min(by + b + ov, Int32(h)))
                    let src = { (x: Int32, y: Int32) in (Int(y - by + c.1) * w + Int(x - bx + c.0)) * ch }
                    // Squared difference between what is there and the block, where both exist.
                    // Minimum-error boundary cuts through the overlaps with the blocks left and above
                    // (computed before this block changes anything).
                    let (left, top): ([Int], [Int]) = out.withUnsafeBufferPointer { ob in
                        filled.withUnsafeBufferPointer { fb in
                            func err(_ x: Int32, _ y: Int32) -> Float {
                                let i = Int(y) * w + Int(x)
                                if !(hole[i] && fb[i]) { return 0 }
                                let a = i * ch, s = src(x, y)
                                var e: Float = -0.0
                                for q in 0..<ch { let d = ob[a + q] - img[s + q]; e += d * d }
                                return e
                            }
                            return (minCut(Int(max(min(bx + ov, x1) - x0, 0)), Int(y1 - y0)) { u, v in err(x0 + Int32(u), y0 + Int32(v)) },
                                    minCut(Int(max(min(by + ov, y1) - y0, 0)), Int(x1 - x0)) { u, v in err(x0 + Int32(v), y0 + Int32(u)) })
                        }
                    }
                    for y in y0..<y1 {
                        for x in x0..<x1 {
                            let i = Int(y) * w + Int(x)
                            if !hole[i] { continue }
                            let (u, v) = (Int(x - x0), Int(y - y0))
                            let keep = filled[i] && ((v < left.count && u < left[v]) || (u < top.count && v < top[u]))
                            if !keep {
                                let a = i * ch, s = src(x, y)
                                for k in 0..<ch { out[a + k] = img[s + k] }
                            }
                            filled[i] = true
                        }
                    }
                }
                bx += b
            }
            by += b
        }
        return out
    }

    /// The minimum-error cut through a band `across` wide and `along` long (Efros & Freeman's
    /// boundary cut): for each step along the band, the offset across it where the cut runs.
    /// Empty when there is no cost anywhere (photocraft `min_cut`).
    static func minCut(_ across: Int, _ along: Int, _ err: (Int, Int) -> Float) -> [Int] {
        if across == 0 || along == 0 { return [] }
        var acc = [Float](repeating: 0, count: across * along)
        for v in 0..<along { for u in 0..<across { acc[v * across + u] = err(u, v) } }
        if acc.allSatisfy({ $0 == 0 }) { return [] }
        for v in 1..<max(along, 1) {
            for u in 0..<across {
                let lo = max(u - 1, 0), hi = min(u + 1, across - 1)
                var m = Float.infinity
                for k in lo...hi { m = Float.minimum(m, acc[(v - 1) * across + k]) }
                acc[v * across + u] += m
            }
        }
        // `min_by(total_cmp)`: the first of equal minima.
        func argmin(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
            var best = lo
            for k in lo...hi {
                let (a, b) = (acc[v * across + k], acc[v * across + best])
                if a.isTotallyOrdered(belowOrEqualTo: b) && !b.isTotallyOrdered(belowOrEqualTo: a) { best = k }
            }
            return best
        }
        var cut = [Int](repeating: 0, count: along)
        var u = argmin(along - 1, 0, across - 1)
        for v in stride(from: along - 1, through: 0, by: -1) {
            if v + 1 < along { u = argmin(v, max(u - 1, 0), min(u + 1, across - 1)) }
            cut[v] = u
        }
        return cut
    }
}

fileprivate extension Int32 {
    /// Rust `saturating_sub`.
    @inline(__always) func subtractingSaturating(_ o: Int32) -> Int32 {
        let (r, ov) = subtractingReportingOverflow(o)
        return ov ? (o > 0 ? .min : .max) : r
    }
}
