// Port of photocraft-algo (crates/algo/src/nonlocal.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Non-local patch-based completion, the Remove Tool's fill: A. Newson, A. Almansa, Y. Gousseau,
// P. Pérez, "Non-Local Patch-Based Image Inpainting", IPOL 7 (2017). Like `complete` it
// alternates PatchMatch with a similarity-weighted vote, coarse to fine, but: texture features
// (local mean |∂x|, |∂y|, weighted by λ) join the patch distance; the coarsest level is
// initialised by onion peeling; the match field (not the image) is upsampled between levels; each
// final pixel comes from the best patch covering it; seams are hidden in the gradient domain (a
// membrane for the hole's edge, a smooth correction for steps between copied areas); and the
// number of levels follows the hole's thickness. CPU only (photocraft's per-iteration convergence
// test and the seam solvers are sequential); deterministic for a seed whatever the thread count.

import Foundation
import PCFoundation

extension InpaintKit {
    /// Parameters for `nonLocalComplete` (photocraft `nonlocal::Params`).
    public struct NonLocalParams: Codable, Sendable, Hashable {
        /// Patch radius (patches are `2r+1` square).
        public var patchRadius: Int = 3
        /// Weight of the texture features against the colour in the patch distance.
        public var lambda: Float = 50
        /// Most EM iterations (search, then vote) per level.
        public var maxIters: Int = 10
        /// PatchMatch passes per EM iteration.
        public var pmPasses: Int = 2
        /// A level is done once an iteration changes the hole by less than this on average.
        public var tolerance: Float = 0.1 / 255
        public var seed: UInt64 = 1
        public init(patchRadius: Int = 3, lambda: Float = 50, maxIters: Int = 10, pmPasses: Int = 2, tolerance: Float = 0.1 / 255, seed: UInt64 = 1) {
            self.patchRadius = patchRadius; self.lambda = lambda; self.maxIters = maxIters; self.pmPasses = pmPasses
            self.tolerance = tolerance; self.seed = seed
        }
    }

    enum NL {
        static let parMin = 128 * 128

        struct Level { var w: Int, h: Int, img: [Float], hole: [Bool] }

        /// Fully-known patch centres, as a mask and a raster-order list.
        static func validSources(_ w: Int, _ h: Int, _ hole: [Bool], _ r: Int) -> ([Bool], [SIMD2<Int32>]) {
            var valid = [Bool](repeating: false, count: w * h)
            var list: [SIMD2<Int32>] = []
            if w < 2 * r + 1 || h < 2 * r + 1 { return (valid, list) }
            let w1 = w + 1
            let sat = integral(w, h, hole)
            for y in r..<(h - r) {
                for x in r..<(w - r) {
                    let (x0, y0, x1, y1) = (x - r, y - r, x + r + 1, y + r + 1)
                    if sat[y1 * w1 + x1] &+ sat[y0 * w1 + x0] == sat[y0 * w1 + x1] &+ sat[y1 * w1 + x0] {
                        valid[y * w + x] = true
                        list.append(SIMD2(Int32(x), Int32(y)))
                    }
                }
            }
            return (valid, list)
        }

        /// The texture features at every known cell: mean |∂x| and |∂y| of the channel mean over
        /// a `side`-wide window, counting only derivatives between two known cells; holes get 0.
        static func textureFeatures(_ w: Int, _ h: Int, _ ch: Int, _ img: [Float], _ hole: [Bool], _ side: Int) -> ([Float], [Float]) {
            let g: [Float] = (0..<(w * h)).map { i in
                var s: Float = -0.0
                for c in 0..<ch { s += img[i * ch + c] }
                return s / Float(ch)
            }
            let w1 = w + 1
            func table(_ dx: Int, _ dy: Int) -> [Float] {
                var sum = [Double](repeating: 0, count: w1 * (h + 1))
                var cnt = [UInt32](repeating: 0, count: w1 * (h + 1))
                for y in 0..<h {
                    var rs = 0.0
                    var rc: UInt32 = 0
                    for x in 0..<w {
                        let i = y * w + x
                        let (nx, ny) = (x + dx, y + dy)
                        if nx < w && ny < h && !hole[i] && !hole[ny * w + nx] {
                            rs += Double(abs(g[ny * w + nx] - g[i]))
                            rc += 1
                        }
                        sum[(y + 1) * w1 + x + 1] = sum[y * w1 + x + 1] + rs
                        cnt[(y + 1) * w1 + x + 1] = cnt[y * w1 + x + 1] + rc
                    }
                }
                let half = side / 2
                return (0..<(w * h)).map { i in
                    if hole[i] { return 0 }
                    let (x, y) = (i % w, i / w)
                    let (x0, y0, x1, y1) = (max(x - half, 0), max(y - half, 0), min(x + half + 1, w), min(y + half + 1, h))
                    let s = sum[y1 * w1 + x1] + sum[y0 * w1 + x0] - sum[y0 * w1 + x1] - sum[y1 * w1 + x0]
                    let n = cnt[y1 * w1 + x1] &+ cnt[y0 * w1 + x0] &- cnt[y0 * w1 + x1] &- cnt[y1 * w1 + x0]
                    return n == 0 ? 0 : Float(s / Double(n))
                }
            }
            return (table(1, 0), table(0, 1))
        }

        /// The next coarser level: colour from a 3×3 Gaussian over the known cells, texture
        /// features by nearest-neighbour subsampling, a cell in the hole when any of its four is.
        static func downsample(_ l: Level, _ cha: Int, _ ch: Int) -> Level {
            let k: [Float] = [0.6412, 0.8007, 0.6412]
            let w = (l.w + 1) / 2, h = (l.h + 1) / 2
            var img = [Float](repeating: 0, count: w * h * cha)
            var hole = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let (fx, fy) = (x * 2, y * 2)
                    let o = (y * w + x) * cha
                    var any = false
                    for dy in 0..<2 { for dx in 0..<2 where fx + dx < l.w && fy + dy < l.h && l.hole[(fy + dy) * l.w + fx + dx] { any = true } }
                    hole[y * w + x] = any
                    var wsum: Float = 0
                    for (ky, oy) in [-1, 0, 1].enumerated() {
                        for (kx, ox) in [-1, 0, 1].enumerated() {
                            let (sx, sy) = (fx + ox, fy + oy)
                            if sx < 0 || sy < 0 || sx >= l.w || sy >= l.h { continue }
                            let si = sy * l.w + sx
                            if l.hole[si] { continue }
                            let kk = k[kx] * k[ky]
                            for c in 0..<ch { img[o + c] += l.img[si * cha + c] * kk }
                            wsum += kk
                        }
                    }
                    if wsum > 0 { for c in 0..<ch { img[o + c] /= wsum } }
                    let si = (fy * l.w + fx) * cha
                    for c in ch..<cha { img[o + c] = l.img[si + c] }
                }
            }
            return Level(w: w, h: h, img: img, hole: hole)
        }

        /// How many levels: ⌈log2(2·No/N)⌉ (at least 1), No the hole's thickness in erosions and N
        /// the patch side, while the coarsest level stays at least three patches across.
        static func levelCount(_ w: Int, _ h: Int, _ hole: [Bool], _ r: Int) -> Int {
            let n = 2 * r + 1
            let no = min(holeRadius(width: w, height: h, hole: hole), 1 << 20)
            let want = Int(Swift.max(log2(2 * Double(no) / Double(n)).rounded(.up), 1))
            var (lw, lh, levels) = (w, h, 1)
            while levels < want && lw / 2 >= 3 * n && lh / 2 >= 3 * n { (lw, lh, levels) = ((lw + 1) / 2, (lh + 1) / 2, levels + 1) }
            return levels
        }

        /// Per-level search and reconstruction state (photocraft `nonlocal::Solver`).
        final class Solver: @unchecked Sendable {
            let w: Int, h: Int, cha: Int, ch: Int, r: Int32
            var img: [Float]
            let hole: [Bool]
            let valid: [Bool]
            let validList: [SIMD2<Int32>]
            let targets: [Bool]
            let ctl: Interrupt

            init(w: Int, h: Int, cha: Int, ch: Int, r: Int32, img: [Float], hole: [Bool], valid: [Bool], validList: [SIMD2<Int32>],
                 targets: [Bool], ctl: Interrupt) {
                self.w = w; self.h = h; self.cha = cha; self.ch = ch; self.r = r; self.img = img; self.hole = hole
                self.valid = valid; self.validList = validList; self.targets = targets; self.ctl = ctl
            }

            @inline(__always)
            func isValid(_ x: Int32, _ y: Int32) -> Bool { x >= 0 && y >= 0 && Int(x) < w && Int(y) < h && valid[Int(y) * w + Int(x)] }

            func randomSource(_ rng: inout Rng) -> SIMD2<Int32> {
                let n = UInt64(max(validList.count, 1))
                let k = Int(rng.next() % n)
                return k < validList.count ? validList[k] : SIMD2(0, 0)
            }

            /// Mean squared difference between the target patch at `t` (clipped to the grid; with
            /// `known`, only its known cells) and the source patch at `s`; ∞ once it can't beat
            /// `cutoff` (only without `known`).
            func dist(_ img: UnsafePointer<Float>, _ tx0: Int32, _ ty0: Int32, _ sx0: Int32, _ sy0: Int32, _ cutoff: Float,
                      _ known: UnsafePointer<Bool>?) -> Float {
                let (w, h, cha, r) = (Int32(self.w), Int32(self.h), self.cha, self.r)
                let full = Float((2 * r + 1) * (2 * r + 1)) * Float(cha)
                var sum: Float = 0
                var n = 0
                var dy = -r
                while dy <= r {
                    let ty = ty0 + dy
                    if ty >= 0 && ty < h {
                        var dx = -r
                        while dx <= r {
                            let tx = tx0 + dx
                            if tx >= 0 && tx < w {
                                let tc = Int(ty) * self.w + Int(tx)
                                if known == nil || known![tc] {
                                    let ti = tc * cha, si = (Int(sy0 + dy) * self.w + Int(sx0 + dx)) * cha
                                    var c = 0
                                    while c < cha { let d = img[ti + c] - img[si + c]; sum += d * d; c += 1 }
                                    n += cha
                                }
                            }
                            dx += 1
                        }
                        if known == nil && sum > cutoff * full { return .infinity }
                    }
                    dy += 1
                }
                return n == 0 ? .infinity : sum / Float(n)
            }

            /// One PatchMatch pass over the targets, in parallel row bands of 16 grid rows.
            func patchmatch(_ nnf: inout [SIMD2<Int32>], _ cost: inout [Float], _ pass: Int, _ seed: UInt64, _ radius: Int32) {
                let band = 16
                let (w, h) = (self.w, self.h)
                let reverse = pass % 2 == 1
                let step: Int32 = reverse ? -1 : 1
                let nb = (h + band - 1) / band
                img.withUnsafeBufferPointer { ib in
                    targets.withUnsafeBufferPointer { tgb in
                        nnf.withUnsafeMutableBufferPointer { nb0 in
                            cost.withUnsafeMutableBufferPointer { cb0 in
                                let (iS, tS, nS, cS) = (UnsafeSendable(ib.baseAddress!), UnsafeSendable(tgb.baseAddress!),
                                                        UnsafeSendable(nb0.baseAddress!), UnsafeSendable(cb0.baseAddress!))
                                let bandFn = { (bi: Int) in
                                    if self.ctl.cancelled { return }
                                    var rng = Rng(seed ^ (UInt64(bi) &* 0x2545_F491_4F6C_DD1D) ^ (UInt64(pass) << 40))
                                    let rows = min(band, h - bi * band)
                                    let nn = nS.value + bi * band * w, co = cS.value + bi * band * w
                                    let img = iS.value, tg = tS.value
                                    var ry = 0
                                    while ry < rows {
                                        let ly = reverse ? rows - 1 - ry : ry
                                        let y = bi * band + ly
                                        var rx = 0
                                        while rx < w {
                                            let x = reverse ? w - 1 - rx : rx
                                            rx += 1
                                            if !tg[y * w + x] { continue }
                                            let li = ly * w + x
                                            let (tx, ty) = (Int32(x), Int32(y))
                                            var bx = nn[li].x, by = nn[li].y, bc = co[li]
                                            @inline(__always) func tryCand(_ cx: Int32, _ cy: Int32) {
                                                if (cx != bx || cy != by) && self.isValid(cx, cy) {
                                                    let d = self.dist(img, tx, ty, cx, cy, bc, nil)
                                                    if d < bc { bx = cx; by = cy; bc = d }
                                                }
                                            }
                                            // Propagation from the neighbours visited before, within this band.
                                            let nx = x - Int(step)
                                            if nx >= 0 && nx < w { let c = nn[ly * w + nx]; tryCand(c.x + step, c.y) }
                                            let nly = ly - Int(step)
                                            if nly >= 0 && nly < rows { let c = nn[nly * w + x]; tryCand(c.x, c.y + step) }
                                            // Random search in exponentially shrinking windows.
                                            var rad = radius
                                            while rad >= 1 {
                                                let cx = bx &+ rng.range(-rad, rad)
                                                let cy = by &+ rng.range(-rad, rad)
                                                tryCand(cx, cy)
                                                rad /= 2
                                            }
                                            nn[li] = SIMD2(bx, by)
                                            co[li] = bc
                                        }
                                        ry += 1
                                    }
                                }
                                if w * h >= parMin { parallelFor(nb, bandFn) } else { for bi in 0..<nb { bandFn(bi) } }
                            }
                        }
                    }
                }
            }

            /// Refresh every target's distance to its current match.
            func refreshCosts(_ nnf: [SIMD2<Int32>], _ cost: inout [Float]) {
                let w = self.w
                img.withUnsafeBufferPointer { ib in
                    cost.withUnsafeMutableBufferPointer { cb in
                        let (iS, cS) = (UnsafeSendable(ib.baseAddress!), UnsafeSendable(cb))
                        parallelChunks(cb.count, minChunk: 1024) { r in
                            for i in r {
                                cS.value[i] = self.targets[i] ? self.dist(iS.value, Int32(i % w), Int32(i / w), nnf[i].x, nnf[i].y, .infinity, nil) : .infinity
                            }
                        }
                    }
                }
            }

            /// The cells of the patches covering hole cell `(x, y)`: each match's source cell for it,
            /// with that patch's cost.
            @inline(__always)
            func sources(_ x: Int, _ y: Int, _ nnf: UnsafePointer<SIMD2<Int32>>, _ cost: UnsafePointer<Float>, _ f: (Int, Float) -> Void) {
                let (w, h, r) = (Int32(self.w), Int32(self.h), self.r)
                for dy in -r...r {
                    let ty = Int32(y) + dy
                    if ty < 0 || ty >= h { continue }
                    for dx in -r...r {
                        let tx = Int32(x) + dx
                        if tx < 0 || tx >= w { continue }
                        let ti = Int(ty) * self.w + Int(tx)
                        if !targets[ti] || !cost[ti].isFinite { continue }
                        let s = nnf[ti]
                        let (sx, sy) = (s.x - dx, s.y - dy)
                        if sx >= 0 && sy >= 0 && sx < w && sy < h { f(Int(sy) * self.w + Int(sx), cost[ti]) }
                    }
                }
            }

            static func sigma2(_ cs: [Float]) -> Float {
                if cs.isEmpty { return 1 }
                let k = min(cs.count * 3 / 4, cs.count - 1)
                return Float.maximum(ToneKit.totalSorted(cs)[k], 1e-6)
            }

            /// Re-estimate the hole by the similarity-weighted vote of the overlapping matches
            /// (`uniform`: all weights 1). Returns the mean absolute change of the colour channels.
            func vote(_ nnf: [SIMD2<Int32>], _ cost: [Float], _ uniform: Bool) -> Float {
                var cs: [Float] = []
                for i in 0..<cost.count where targets[i] && cost[i].isFinite { cs.append(cost[i]) }
                let s2 = Self.sigma2(cs)
                let cha = self.cha
                var newVals = [Float](repeating: 0, count: w * h * cha)
                var got = [Bool](repeating: false, count: w * h)
                img.withUnsafeBufferPointer { ib in
                    nnf.withUnsafeBufferPointer { nb in
                        cost.withUnsafeBufferPointer { cb in
                            newVals.withUnsafeMutableBufferPointer { vb in
                                got.withUnsafeMutableBufferPointer { gb in
                                    let (iS, nS, cS, vS, gS) = (UnsafeSendable(ib), UnsafeSendable(nb.baseAddress!), UnsafeSendable(cb.baseAddress!),
                                                                UnsafeSendable(vb), UnsafeSendable(gb))
                                    let rowFn = { (y: Int) in
                                        if self.ctl.cancelled { return }
                                        var v = [Float](repeating: 0, count: cha)
                                        for x in 0..<self.w where self.hole[y * self.w + x] {
                                            for c in 0..<cha { v[c] = 0 }
                                            var wsum: Float = 0
                                            self.sources(x, y, nS.value, cS.value) { si, c in
                                                let wt: Float = uniform ? 1 : Float.maximum(expf(-c / (2 * s2)), 1e-8)
                                                for k in 0..<cha { v[k] += iS.value[si * cha + k] * wt }
                                                wsum += wt
                                            }
                                            if wsum > 0 {
                                                let i = y * self.w + x
                                                for k in 0..<cha { vS.value[i * cha + k] = v[k] / wsum }
                                                gS.value[i] = true
                                            }
                                        }
                                    }
                                    if w * h >= parMin { parallelChunks(h, minChunk: 4) { r in for y in r { rowFn(y) } } } else { for y in 0..<h { rowFn(y) } }
                                }
                            }
                        }
                    }
                }
                var change = 0.0
                var n = 0
                for i in 0..<(w * h) where got[i] {
                    for c in 0..<ch { change += Double(abs(newVals[i * cha + c] - img[i * cha + c])) }
                    n += ch
                    for c in 0..<cha { img[i * cha + c] = newVals[i * cha + c] }
                }
                return n == 0 ? 0 : Float(change / Double(n))
            }

            /// Each hole cell copies the source cell of the lowest-cost patch covering it. Returns
            /// `(hole cell, source cell, that patch's cost)`.
            func copyBest(_ nnf: [SIMD2<Int32>], _ cost: [Float]) -> [(Int, Int, Float)] {
                var picked: [(Int, Int, Float)] = []
                nnf.withUnsafeBufferPointer { nb in
                    cost.withUnsafeBufferPointer { cb in
                        for y in 0..<h {
                            for x in 0..<w where hole[y * w + x] {
                                var best: (Int, Float)?
                                sources(x, y, nb.baseAddress!, cb.baseAddress!) { si, c in
                                    if best.map({ c < $0.1 }) ?? true { best = (si, c) }
                                }
                                if let b = best { picked.append((y * w + x, b.0, b.1)) }
                            }
                        }
                    }
                }
                for (i, si, _) in picked { for c in 0..<cha { img[i * cha + c] = img[si * cha + c] } }
                return picked
            }

            /// Hide the colour seam along the hole's edge in the gradient domain (Pérez et al., Poisson
            /// Image Editing, 2003): the median edge mismatch, capped, spread over the hole as a
            /// membrane and added to the fill.
            func blendSeams(_ copied: [(Int, Int, Float)], _ textureScale: Float) {
                let edgeMedian = 8
                let maxShift: Float = 0.05
                let (w, h, cha, ch) = (self.w, self.h, self.cha, self.ch)
                if copied.isEmpty { return }
                let unscale: Float = textureScale > 0 ? 0.5 / textureScale : 0
                var (x0, y0, x1, y1) = (w, h, 0, 0)
                for (p, _, _) in copied { x0 = min(x0, p % w); y0 = min(y0, p / w); x1 = max(x1, p % w + 1); y1 = max(y1, p / w + 1) }
                (x0, y0, x1, y1) = (max(x0 - 1, 0), max(y0 - 1, 0), min(x1 + 1, w), min(y1 + 1, h))
                let (bw, bh) = (max(x1 - x0, 0), max(y1 - y0, 0))
                let local = { (i: Int) in (i / w - y0) * bw + (i % w - x0) }
                let img = self.img, hole = self.hole
                func channel(_ c: Int) -> [Float] {
                    var v = [Float](repeating: 0, count: bw * bh)
                    var n = [UInt8](repeating: 0, count: bw * bh)
                    @inline(__always) func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h }
                    for (p, s, _) in copied {
                        let (px, py, sx, sy) = (p % w, p / w, s % w, s / w)
                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                            let (qx, qy, tx, ty) = (px + dx, py + dy, sx + dx, sy + dy)
                            if !inside(qx, qy) || !inside(tx, ty) { continue }
                            let (q, t) = (qy * w + qx, ty * w + tx)
                            if hole[q] { continue }
                            let lq = local(q)
                            v[lq] += img[q * cha + c] - img[t * cha + c]
                            n[lq] = n[lq] == .max ? .max : n[lq] + 1
                        }
                    }
                    for i in 0..<v.count where n[i] > 0 { v[i] /= Float(n[i]) }
                    // Each edge cell takes the median difference of the edge cells around it, capped.
                    let raw = v
                    var near: [Float] = []
                    for lq in 0..<(bw * bh) where n[lq] > 0 {
                        let (qx, qy) = (lq % bw, lq / bw)
                        near.removeAll(keepingCapacity: true)
                        for y in max(qy - edgeMedian, 0)..<min(qy + edgeMedian + 1, bh) {
                            for x in max(qx - edgeMedian, 0)..<min(qx + edgeMedian + 1, bw) where n[y * bw + x] > 0 { near.append(raw[y * bw + x]) }
                        }
                        if !near.isEmpty {
                            let m = ToneKit.totalSorted(near)[near.count / 2]
                            let q = (y0 + qy) * w + x0 + qx
                            let texture = (img[q * cha + ch] + img[q * cha + ch + 1]) * unscale
                            let cap = maxShift + 2 * texture
                            v[lq] = m < -cap ? -cap : (m > cap ? cap : m)
                        }
                    }
                    // Known cells off the ring take the value of the nearest ring cell (breadth first).
                    var queue = Deque<Int>()
                    for lq in 0..<(bw * bh) where n[lq] > 0 { queue.pushBack(lq) }
                    var seen = n.map { $0 > 0 }
                    let inHole = { (lq: Int) in hole[(y0 + lq / bw) * w + x0 + lq % bw] }
                    while let lq = queue.popFront() {
                        let (x, y) = (lq % bw, lq / bw)
                        var around: [Int] = []
                        if x > 0 { around.append(lq - 1) }
                        if x + 1 < bw { around.append(lq + 1) }
                        if y > 0 { around.append(lq - bw) }
                        if y + 1 < bh { around.append(lq + bw) }
                        for nb in around where !seen[nb] && !inHole(nb) {
                            seen[nb] = true
                            v[nb] = v[lq]
                            queue.pushBack(nb)
                        }
                    }
                    let unknown = (0..<(bw * bh)).map(inHole)
                    Poisson.solveMembrane(width: bw, height: bh, unknown: unknown, values: &v)
                    return v
                }
                var shifts = [[Float]](repeating: [], count: ch)
                shifts.withUnsafeMutableBufferPointer { sb in
                    let sS = UnsafeSendable(sb)
                    parallelFor(ch) { c in sS.value[c] = channel(c) }
                }
                for (p, _, _) in copied {
                    let lp = local(p)
                    for c in 0..<ch { self.img[p * cha + c] += shifts[c][lp] }
                }
            }

            /// Remove the visible seams between areas copied from different places (gradient-domain
            /// fusion after Image Melding): a correction solved (red-black SOR) for the steps that
            /// depart from what the sources predict by more than 3× the local texture.
            func fuseSeams(_ copied: [(Int, Int, Float)], _ textureScale: Float, _ iters: Int) {
                let seamContrast: Float = 3
                let omega: Float = 1.8
                let (w, h, cha, ch) = (self.w, self.h, self.cha, self.ch)
                var src = [(Int, Float)](repeating: (Int.max, .infinity), count: w * h)
                for (p, s, c) in copied { src[p] = (s, c) }
                @inline(__always) func cell(_ x: Int, _ y: Int) -> Int? { x >= 0 && y >= 0 && x < w && y < h ? y * w + x : nil }
                let unscale: Float = textureScale > 0 ? 0.5 / textureScale : 0
                var div = [Float](repeating: 0, count: w * h * ch)
                var any = false
                var e = [Float](repeating: 0, count: ch)
                for (p, sp, cp) in copied {
                    let (px, py) = (p % w, p / w)
                    let texture = (img[p * cha + ch] + img[p * cha + ch + 1]) * unscale
                    for (dx, dy) in [(1, 0), (0, 1)] {
                        guard let q = cell(px + dx, py + dy) else { continue }
                        let (sq, cq) = src[q]
                        if sq == Int.max { continue }
                        // The step each side's source predicts.
                        let fromP = cell(sp % w + dx, sp / w + dy)
                        if fromP == sq { continue }
                        let fromQ = cell(sq % w - dx, sq / w - dy)
                        let a: Int, b: Int
                        switch (fromP, fromQ) {
                        case let (.some(n), .some(m)): (a, b) = cp <= cq ? (sp, n) : (m, sq)
                        case let (.some(n), .none): (a, b) = (sp, n)
                        case let (.none, .some(m)): (a, b) = (m, sq)
                        default: continue
                        }
                        var sumAbs: Float = -0.0
                        for c in 0..<ch {
                            e[c] = (img[b * cha + c] - img[a * cha + c]) - (img[q * cha + c] - img[p * cha + c])
                            sumAbs += abs(e[c])
                        }
                        if sumAbs / Float(ch) <= seamContrast * texture { continue }
                        for c in 0..<ch { div[p * ch + c] += e[c]; div[q * ch + c] -= e[c] }
                        any = true
                    }
                }
                if !any { return }
                let fuseBand = 16
                let seams = (0..<(w * h)).map { i in (0..<ch).contains { div[i * ch + $0] != 0 } }
                let band = dilate(width: w, height: h, mask: seams, radius: fuseBand)
                let halves: [[Int]] = [0, 1].map { colour in copied.map(\.0).filter { band[$0] && ($0 % w + $0 / w) % 2 == colour } }
                var delta = [Float](repeating: 0, count: w * h * ch)
                for _ in 0..<iters {
                    if ctl.cancelled { return }
                    for cells in halves {
                        var next = [Float](repeating: 0, count: cells.count * ch)
                        delta.withUnsafeBufferPointer { db in
                            next.withUnsafeMutableBufferPointer { nb in
                                let (dS, nS) = (UnsafeSendable(db.baseAddress!), UnsafeSendable(nb))
                                parallelChunks(cells.count, minChunk: 256) { r in
                                    for idx in r {
                                        let p = cells[idx]
                                        let (x, y) = (p % w, p / w)
                                        var deg: Float = 0
                                        let o = idx * ch
                                        for c in 0..<ch { nS.value[o + c] = 0 }
                                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                                            guard let q = cell(x + dx, y + dy) else { continue }
                                            deg += 1
                                            for c in 0..<ch { nS.value[o + c] += dS.value[q * ch + c] }
                                        }
                                        for c in 0..<ch {
                                            let cur = dS.value[p * ch + c]
                                            nS.value[o + c] = cur + omega * ((nS.value[o + c] - div[p * ch + c]) / Float.maximum(deg, 1) - cur)
                                        }
                                    }
                                }
                            }
                        }
                        for (idx, p) in cells.enumerated() { for c in 0..<ch { delta[p * ch + c] = next[idx * ch + c] } }
                    }
                }
                for (p, _, _) in copied { for c in 0..<ch { img[p * cha + c] += delta[p * ch + c] } }
            }

            /// Onion-peel initialisation (the paper's §3.4): fill the hole one boundary layer at a
            /// time from matches of the known patch centres next to it. Leaves those matches in `nnf`.
            func onionPeel(_ nnf: inout [SIMD2<Int32>], _ has: inout [Bool], _ seed: UInt64) throws {
                let (w, h, r, cha) = (self.w, self.h, self.r, self.cha)
                var known = hole.map { !$0 }
                var unknown = (0..<(w * h)).filter { hole[$0] }
                var centre = [Bool](repeating: false, count: w * h)
                var layerCost = [Float](repeating: .infinity, count: w * h)
                var layerNo: UInt64 = 0
                while true {
                    try ctl.check()
                    let layer = unknown.filter { i in
                        let (x, y) = (i % w, i / w)
                        return (x > 0 && known[i - 1]) || (x + 1 < w && known[i + 1]) || (y > 0 && known[i - w]) || (y + 1 < h && known[i + w])
                    }
                    if layer.isEmpty { return }
                    // Known centres whose patch reaches into the layer.
                    var centres: [Int] = []
                    for i in layer {
                        let (x, y) = (Int32(i % w), Int32(i / w))
                        for cy in max(y - r, 0)...min(y + r, Int32(h) - 1) {
                            for cx in max(x - r, 0)...min(x + r, Int32(w) - 1) {
                                let ci = Int(cy) * w + Int(cx)
                                if known[ci] && !centre[ci] { centre[ci] = true; centres.append(ci) }
                            }
                        }
                    }
                    for ci in centres { centre[ci] = false }
                    var foundS = [SIMD2<Int32>](repeating: .zero, count: centres.count)
                    var foundC = [Float](repeating: .infinity, count: centres.count)
                    let ln = layerNo
                    img.withUnsafeBufferPointer { ib in
                        known.withUnsafeBufferPointer { kb in
                            nnf.withUnsafeBufferPointer { nb in
                                has.withUnsafeBufferPointer { hb in
                                    foundS.withUnsafeMutableBufferPointer { fsb in
                                        foundC.withUnsafeMutableBufferPointer { fcb in
                                            let (iS, kS, nS, hS) = (UnsafeSendable(ib.baseAddress!), UnsafeSendable(kb.baseAddress!),
                                                                    UnsafeSendable(nb.baseAddress!), UnsafeSendable(hb.baseAddress!))
                                            let (fsS, fcS) = (UnsafeSendable(fsb), UnsafeSendable(fcb))
                                            let offsets: [SIMD2<Int32>] = [SIMD2(-1, 0), SIMD2(1, 0), SIMD2(0, -1), SIMD2(0, 1)]
                                            parallelFor(centres.count) { j in
                                                let ci = centres[j]
                                                let (tx, ty) = (Int32(ci % w), Int32(ci / w))
                                                var rng = Rng(seed ^ (UInt64(ci) &* 0x9E37_79B9) ^ (ln << 48))
                                                var bx: Int32 = 0, by: Int32 = 0
                                                var bc = Float.infinity
                                                @inline(__always) func tryCand(_ cx: Int32, _ cy: Int32) {
                                                    if self.isValid(cx, cy) {
                                                        let d = self.dist(iS.value, tx, ty, cx, cy, bc, kS.value)
                                                        if d < bc { bx = cx; by = cy; bc = d }
                                                    }
                                                }
                                                if hS.value[ci] { tryCand(nS.value[ci].x, nS.value[ci].y) }
                                                for o in offsets {
                                                    let (nx, ny) = (tx + o.x, ty + o.y)
                                                    if nx >= 0 && ny >= 0 && Int(nx) < w && Int(ny) < h && hS.value[Int(ny) * w + Int(nx)] {
                                                        let s = nS.value[Int(ny) * w + Int(nx)]
                                                        tryCand(s.x - o.x, s.y - o.y)
                                                    }
                                                }
                                                for _ in 0..<8 { let s = self.randomSource(&rng); tryCand(s.x, s.y) }
                                                for _ in 0..<2 {
                                                    var rad = Int32(max(w, h))
                                                    while rad >= 1 {
                                                        let cx = bx &+ rng.range(-rad, rad)
                                                        let cy = by &+ rng.range(-rad, rad)
                                                        tryCand(cx, cy)
                                                        rad /= 2
                                                    }
                                                }
                                                fsS.value[j] = SIMD2(bx, by)
                                                fcS.value[j] = bc
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    var cs: [Float] = []
                    for (j, ci) in centres.enumerated() where foundC[j].isFinite {
                        nnf[ci] = foundS[j]
                        has[ci] = true
                        layerCost[ci] = foundC[j]
                        cs.append(foundC[j])
                    }
                    let s2 = Self.sigma2(cs)
                    var values: [(Int, [Float])] = []
                    for i in layer {
                        let (x, y) = (Int32(i % w), Int32(i / w))
                        var v = [Float](repeating: 0, count: cha)
                        var wsum: Float = 0
                        for cy in max(y - r, 0)...min(y + r, Int32(h) - 1) {
                            for cx in max(x - r, 0)...min(x + r, Int32(w) - 1) {
                                let ci = Int(cy) * w + Int(cx)
                                if !layerCost[ci].isFinite { continue }
                                let s = nnf[ci]
                                let (sx, sy) = (s.x + x - cx, s.y + y - cy)
                                if sx < 0 || sy < 0 || Int(sx) >= w || Int(sy) >= h { continue }
                                let si = Int(sy) * w + Int(sx)
                                let wt = Float.maximum(expf(-layerCost[ci] / (2 * s2)), 1e-8)
                                for k in 0..<cha { v[k] += img[si * cha + k] * wt }
                                wsum += wt
                            }
                        }
                        if wsum > 0 {
                            for k in 0..<cha { v[k] /= wsum }
                            values.append((i, v))
                        }
                    }
                    for ci in centres { layerCost[ci] = .infinity }
                    if values.isEmpty { return }
                    for (i, v) in values {
                        for k in 0..<cha { img[i * cha + k] = v[k] }
                        known[i] = true
                    }
                    unknown.removeAll { known[$0] }
                    layerNo += 1
                }
            }
        }
    }

    /// Non-local patch-based completion of `hole` in `img` (photocraft `nonlocal::complete_with`).
    /// nil when no fully-known patch exists to copy from; a buffer or mask of the wrong size, or no
    /// hole, comes back unchanged.
    public static func nonLocalComplete(width w: Int, height h: Int, channels ch: Int, image img: [Float], hole: [Bool],
                                        params p: NonLocalParams = NonLocalParams(), interrupt ctl: Interrupt = .none) throws -> [Float]? {
        let n = w * h
        if ch == 0 || hole.count != n || img.count != n * ch || !hole.contains(true) { return img }
        let r = max(p.patchRadius, 1)
        let levels = NL.levelCount(w, h, hole, r)
        // Texture features at full resolution, averaged over about a coarsest-level cell.
        let (tx, ty) = NL.textureFeatures(w, h, ch, img, hole, 1 << min(levels, 8))
        let cha = ch + 2
        let k = Float.maximum(p.lambda, 0).squareRoot()
        var data = [Float]()
        data.reserveCapacity(n * cha)
        for i in 0..<n {
            for c in 0..<ch { data.append(img[i * ch + c]) }
            data.append(tx[i] * k); data.append(ty[i] * k)
        }
        var pyramid = [NL.Level(w: w, h: h, img: data, hole: hole)]
        while pyramid.count < levels {
            try ctl.check()
            let next = NL.downsample(pyramid[pyramid.count - 1], cha, ch)
            // A level with nothing to copy from can't seed the finer ones: stop above it.
            if NL.validSources(next.w, next.h, next.hole, r).1.isEmpty { break }
            pyramid.append(next)
        }
        let totalPx = pyramid.reduce(0) { $0 + $1.w * $1.h }
        var donePx = 0
        var prev: (Int, [SIMD2<Int32>])?
        var result: [Float]?
        for li in stride(from: pyramid.count - 1, through: 0, by: -1) {
            try ctl.check()
            let level = pyramid[li]
            let (lw, lh) = (level.w, level.h)
            let (valid, validList) = NL.validSources(lw, lh, level.hole, r)
            if validList.isEmpty { return nil }
            let ri = Int32(r)
            var targets = [Bool](repeating: false, count: lw * lh)
            for i in 0..<(lw * lh) where level.hole[i] {
                let (x, y) = (Int32(i % lw), Int32(i / lw))
                for ty in max(y - ri, 0)...min(y + ri, Int32(lh) - 1) {
                    for tx in max(x - ri, 0)...min(x + ri, Int32(lw) - 1) { targets[Int(ty) * lw + Int(tx)] = true }
                }
            }
            let s = NL.Solver(w: lw, h: lh, cha: cha, ch: ch, r: ri, img: level.img, hole: level.hole, valid: valid, validList: validList,
                              targets: targets, ctl: ctl)
            var nnf = [SIMD2<Int32>](repeating: .zero, count: lw * lh)
            var cost = [Float](repeating: .infinity, count: lw * lh)
            var rng = Rng(p.seed ^ (UInt64(li) << 20))
            if let (pw, pnnf) = prev {
                // Upsample the coarser match field, then rebuild the hole from it.
                for y in 0..<lh {
                    for x in 0..<lw {
                        let i = y * lw + x
                        if !targets[i] { continue }
                        let pi = (y / 2) * pw + x / 2
                        let c = pi < pnnf.count ? pnnf[pi] : SIMD2<Int32>(-1, -1)
                        let cand = SIMD2(c.x * 2 + Int32(x % 2), c.y * 2 + Int32(y % 2))
                        if s.isValid(cand.x, cand.y) { nnf[i] = cand }
                        else if s.isValid(c.x * 2, c.y * 2) { nnf[i] = SIMD2(c.x * 2, c.y * 2) }
                        else { nnf[i] = s.randomSource(&rng) }
                    }
                }
                // Uniform weights: the costs only need to be finite.
                for i in 0..<cost.count where targets[i] { cost[i] = 0 }
                _ = s.vote(nnf, cost, true)
            } else {
                // Coarsest level: onion peel, then random matches for the targets it didn't reach.
                var has = [Bool](repeating: false, count: lw * lh)
                try s.onionPeel(&nnf, &has, p.seed ^ 0x0c10_4e00)
                for i in 0..<(lw * lh) where targets[i] && !has[i] { nnf[i] = s.randomSource(&rng) }
            }
            prev = nil
            // Wide random search at the coarsest level; finer levels refine the upsampled field.
            let coarsest = li + 1 == pyramid.count
            let full = Int32(max(lw, lh))
            for it in 0..<max(p.maxIters, 1) {
                try ctl.check()
                s.refreshCosts(nnf, &cost)
                let radius = coarsest || it == 0 ? full : min(8 * (2 * ri + 1), full)
                for pass in 0..<max(p.pmPasses, 1) {
                    try ctl.check()
                    s.patchmatch(&nnf, &cost, pass + it * p.pmPasses, p.seed &+ UInt64(li * 1000 + it), radius)
                }
                try ctl.check()
                let change = s.vote(nnf, cost, false)
                try ctl.check()
                if change < p.tolerance { break }
            }
            if li == 0 {
                s.refreshCosts(nnf, &cost)
                let copied = s.copyBest(nnf, cost)
                try ctl.check()
                s.blendSeams(copied, k)
                try ctl.check()
                s.fuseSeams(copied, k, 100)
                try ctl.check()
                result = s.img
            }
            donePx += lw * lh
            ctl.report(Float(donePx) / Float(max(totalPx, 1)))
            prev = (lw, nnf)
        }
        guard let data2 = result else { return nil }
        // The colour channels; known cells exactly as given.
        var out = img
        for i in 0..<n where hole[i] { for c in 0..<ch { out[i * ch + c] = data2[i * cha + c] } }
        return out
    }
}
