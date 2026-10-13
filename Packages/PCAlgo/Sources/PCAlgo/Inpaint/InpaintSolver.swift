// Port of photocraft-algo (crates/algo/src/inpaint.rs: Solver — prepare, dist, moments, transform, pm_step, patchmatch, costs, vote; Votes), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The per-level PatchMatch / EM state of the completion (Barnes et al., PatchMatch, SIGGRAPH
// 2009; Wexler et al., Space-Time Completion, TPAMI 2007; Darabi et al., Image Melding, SIGGRAPH
// 2012). Every sum runs in photocraft's order, so distances, costs and votes are bit-identical
// to the reference; PatchMatch runs per band of 16 grid rows (propagation stays inside a band,
// each band seeded by its index), so the result never depends on the thread count.

import Metal
import PCFoundation

extension InpaintKit {
    /// A buffer the CPU and (when given a device) the GPU share: shared-storage Metal memory or a
    /// plain allocation (trivial element types only).
    final class Store<T: BitwiseCopyable>: @unchecked Sendable {
        let ptr: UnsafeMutablePointer<T>
        let count: Int
        let buffer: (any MTLBuffer)?

        private init(count: Int, device: (any MTLDevice)?, fill: (UnsafeMutablePointer<T>) -> Void) {
            self.count = count
            let bytes = max(count * MemoryLayout<T>.stride, 16)
            if let dev = device, let b = dev.makeBuffer(length: bytes, options: .storageModeShared) {
                buffer = b
                ptr = b.contents().bindMemory(to: T.self, capacity: max(count, 1))
            } else {
                buffer = nil
                ptr = .allocate(capacity: max(count, 1))
            }
            fill(ptr)
        }

        convenience init(_ count: Int, _ initial: T, device: (any MTLDevice)?) {
            self.init(count: count, device: device) { $0.initialize(repeating: initial, count: count) }
        }

        convenience init(_ values: [T], device: (any MTLDevice)?) {
            self.init(count: values.count, device: device) { p in
                values.withUnsafeBufferPointer { s in if let b = s.baseAddress { p.initialize(from: b, count: s.count) } }
            }
        }

        var array: [T] { Array(UnsafeBufferPointer(start: ptr, count: count)) }

        deinit { if buffer == nil { ptr.deallocate() } }
    }

    /// Per-level PatchMatch/EM state (photocraft `Solver`).
    final class Solver: @unchecked Sendable {
        let w: Int, h: Int, ch: Int, r: Int32
        let img: Store<Float>
        let px: Store<Px>
        /// Valid source centres: the whole patch is inside the grid and may be copied from.
        let valid: Store<Bool>
        let holeBox: Bounds, tbox: Bounds
        /// Target centres (the patch overlaps the hole), over `tbox`.
        let targets: Store<Bool>
        /// Per cell of `tbox`: the whole patch is inside the grid and not void.
        var full: Store<Bool>
        /// With colour adaptation, per cell of `tbox` and channel: Σt, Σt² of full patches.
        var tmom: Store<SIMD2<Float>>?
        /// With colour adaptation where it pays: per source centre and channel, Σs, Σs².
        var smom: Store<SIMD2<Float>>?
        let adapt: Adapt
        let ctl: Interrupt
        let gpu: InpaintGPU?

        var c8: Int { min(ch, momCh) }
        var side: Int { Int(2 * r + 1) }
        /// Raw pointers of the tables (the stores live as long as the solver).
        let imgP: UnsafeMutablePointer<Float>
        let pxP: UnsafeMutablePointer<Px>
        let validP: UnsafeMutablePointer<Bool>
        let targetsP: UnsafeMutablePointer<Bool>
        var fullP: UnsafeMutablePointer<Bool>
        var tmomP: UnsafeMutablePointer<SIMD2<Float>>?
        var smomP: UnsafeMutablePointer<SIMD2<Float>>?
        let adaptNone: Bool

        init(w: Int, h: Int, ch: Int, r: Int32, img: Store<Float>, px: Store<Px>, valid: [Bool], holeBox: Bounds, tbox: Bounds,
             targets: [Bool], adapt: Adapt, ctl: Interrupt, gpu: InpaintGPU?) {
            self.w = w; self.h = h; self.ch = ch; self.r = r; self.img = img; self.px = px
            let dev = gpu?.device
            self.valid = Store(valid, device: dev)
            self.holeBox = holeBox; self.tbox = tbox
            self.targets = Store(targets, device: dev)
            self.full = Store(0, false, device: nil)
            self.adapt = adapt; self.ctl = ctl; self.gpu = gpu
            imgP = img.ptr; pxP = px.ptr; validP = self.valid.ptr; targetsP = self.targets.ptr; fullP = self.full.ptr
            adaptNone = adapt.isNone
        }

        @inline(__always)
        func isValid(_ x: Int32, _ y: Int32) -> Bool {
            x >= 0 && y >= 0 && Int(x) < w && Int(y) < h && validP[Int(y) * w + Int(x)]
        }

        /// Mark the full target patches, and keep the source moments where they pay off.
        func prepare(_ keepSourceMoments: Bool) {
            let (w, h, r, tb) = (self.w, self.h, Int(self.r), self.tbox)
            let side = 2 * r + 1
            let f = Store(tb.area, false, device: gpu?.device)
            let (pxp, fp) = (UnsafeSendable(px.ptr), UnsafeSendable(f.ptr))
            let rowFn = { (ty: Int) in
                let y = tb.y0 + ty
                if y < r || y + r >= h { return }
                for tx in 0..<tb.width {
                    let x = tb.x0 + tx
                    if x < r || x + r >= w { continue }
                    var ok = true
                    outer: for yy in (y - r)...(y + r) {
                        for xx in (x - r)..<(x - r + side) where pxp.value[yy * w + xx] == .void { ok = false; break outer }
                    }
                    fp.value[ty * tb.width + tx] = ok
                }
            }
            if tb.area >= parMinPatches { parallelChunks(tb.height, minChunk: 2) { rr in for ty in rr { rowFn(ty) } } }
            else { for ty in 0..<tb.height { rowFn(ty) } }
            full = f
            fullP = f.ptr
            if adapt.isNone { return }
            let c8 = self.c8
            tmom = Store(tb.area * c8, SIMD2<Float>.zero, device: gpu?.device)
            tmomP = tmom?.ptr
            if !keepSourceMoments { return }
            let sm = Store(w * h * c8, SIMD2<Float>.zero, device: gpu?.device)
            if let g = gpu, g.sourceMoments(self, into: sm) {
                smom = sm
                smomP = sm.ptr
                return
            }
            let (ip, vp, sp) = (UnsafeSendable(UnsafePointer(img.ptr)), UnsafeSendable(valid.ptr), UnsafeSendable(sm.ptr))
            let ch = self.ch
            let ctl = self.ctl
            let rowM = { (y: Int) in
                if ctl.cancelled { return }
                for x in 0..<w where vp.value[y * w + x] {
                    patchMoments(ip.value, w, ch, c8, side, x - r, y - r, sp.value + (y * w + x) * c8)
                }
            }
            if w * h >= parMinPatches { parallelChunks(h, minChunk: 2) { rr in for y in rr { rowM(y) } } } else { for y in 0..<h { rowM(y) } }
            smom = sm
            smomP = sm.ptr
        }

        /// Distance between the target patch at `t` (`k` its index in the `tbox` tables) and the
        /// source patch at `s`, per sample; with colour adaptation the source is fitted first.
        @inline(__always)
        func dist(_ tx: Int32, _ ty: Int32, _ k: Int, _ sx: Int32, _ sy: Int32, _ cutoff: Float) -> Float {
            let isFull = fullP[k]
            if !adaptNone { return isFull ? distAdaptedFull(k, tx, ty, sx, sy) : distAdapted(tx, ty, sx, sy) }
            return isFull ? distFull(tx, ty, sx, sy, cutoff) : distClipped(tx, ty, sx, sy, cutoff)
        }

        /// `dist` without adaptation, of a patch that may be clipped.
        func distClipped(_ tx0: Int32, _ ty0: Int32, _ sx0: Int32, _ sy0: Int32, _ cutoff: Float) -> Float {
            let (w, h, ch, r) = (Int32(self.w), Int32(self.h), self.ch, self.r)
            let fullN = Float((2 * r + 1) * (2 * r + 1)) * Float(ch)
            let img = imgP, px = pxP
            var sum: Float = 0
            var n = 0
            var dy = -r
            while dy <= r {
                let ty = ty0 + dy
                if ty >= 0 && ty < h {
                    let sy = sy0 + dy
                    var dx = -r
                    while dx <= r {
                        let tx = tx0 + dx
                        if tx >= 0 && tx < w && px[Int(ty) * self.w + Int(tx)] != .void {
                            let ti = (Int(ty) * self.w + Int(tx)) * ch, si = (Int(sy) * self.w + Int(sx0 + dx)) * ch
                            var c = 0
                            while c < ch { let d = img[ti + c] - img[si + c]; sum += d * d; c += 1 }
                            n += ch
                        }
                        dx += 1
                    }
                    // Early out: the mean can only be ≥ sum / (full patch size).
                    if sum > cutoff * fullN { return .infinity }
                }
                dy += 1
            }
            return n == 0 ? .infinity : sum / Float(n)
        }

        /// `distClipped` of a full patch: the same sums, in the same order, giving up as soon as
        /// the sum shows the patch is worse than `cutoff`.
        @inline(__always)
        func distFull(_ tx: Int32, _ ty: Int32, _ sx: Int32, _ sy: Int32, _ cutoff: Float) -> Float {
            let (w, ch, r) = (self.w, self.ch, Int(self.r))
            let side = 2 * r + 1
            let limit = cutoff * (Float(side * side) * Float(ch))
            let img = imgP
            var sum: Float = 0
            var dy = -r
            while dy <= r {
                var tp = img + ((Int(ty) + dy) * w + (Int(tx) - r)) * ch
                var sp = img + ((Int(sy) + dy) * w + (Int(sx) - r)) * ch
                var i = 0
                while i < side {
                    var c = 0
                    while c < ch { let d = tp[c] - sp[c]; sum += d * d; c += 1 }
                    if sum > limit { return .infinity }
                    tp += ch; sp += ch; i += 1
                }
                dy += 1
            }
            return sum / Float(side * side * ch)
        }

        /// Moments of the target patch at `t` and the source patch at `s` per channel:
        /// `[Σt, Σt², Σs, Σs², Σts]` (the first `c8` channels), and the sample count.
        func moments(_ tx0: Int32, _ ty0: Int32, _ sx0: Int32, _ sy0: Int32, _ m: UnsafeMutablePointer<SIMD8<Float>>) -> Int {
            let (w, h, ch, r, c8) = (Int32(self.w), Int32(self.h), self.ch, self.r, self.c8)
            let img = imgP, px = pxP
            var c = 0
            while c < c8 { m[c] = .zero; c += 1 }
            var n = 0
            var dy = -r
            while dy <= r {
                let ty = ty0 + dy
                if ty >= 0 && ty < h {
                    let sy = sy0 + dy
                    var dx = -r
                    while dx <= r {
                        let tx = tx0 + dx
                        if tx >= 0 && tx < w && px[Int(ty) * self.w + Int(tx)] != .void {
                            let ti = (Int(ty) * self.w + Int(tx)) * ch, si = (Int(sy) * self.w + Int(sx0 + dx)) * ch
                            c = 0
                            while c < c8 {
                                let a = img[ti + c], b = img[si + c]
                                m[c][0] += a; m[c][1] += a * a; m[c][2] += b; m[c][3] += b * b; m[c][4] += a * b
                                c += 1
                            }
                            n += 1
                        }
                        dx += 1
                    }
                }
                dy += 1
            }
            return n
        }

        /// `moments` of a full target patch: the target's own sums kept from `costs`, the source's
        /// from `prepare` when kept, each summed in the same order as there.
        func momentsFull(_ k: Int, _ tx: Int32, _ ty: Int32, _ sx: Int32, _ sy: Int32, _ m: UnsafeMutablePointer<SIMD8<Float>>) {
            let (w, ch, r, c8) = (self.w, self.ch, Int(self.r), self.c8)
            let side = 2 * r + 1
            let img = imgP
            let tm = tmomP! + k * c8
            let sm: UnsafeMutablePointer<SIMD2<Float>>? = smomP.map { $0 + (Int(sy) * w + Int(sx)) * c8 }
            var a0 = SIMD8<Float>(), a1 = SIMD8<Float>(), a2 = SIMD8<Float>()   // Σs, Σs², Σts per channel
            var dy = -r
            while dy <= r {
                var tp = img + ((Int(ty) + dy) * w + (Int(tx) - r)) * ch
                var sp = img + ((Int(sy) + dy) * w + (Int(sx) - r)) * ch
                var i = 0
                if sm != nil {
                    while i < side {
                        var c = 0
                        while c < c8 { a2[c] += tp[c] * sp[c]; c += 1 }
                        tp += ch; sp += ch; i += 1
                    }
                } else {
                    while i < side {
                        var c = 0
                        while c < c8 {
                            let a = tp[c], b = sp[c]
                            a0[c] += b; a1[c] += b * b; a2[c] += a * b
                            c += 1
                        }
                        tp += ch; sp += ch; i += 1
                    }
                }
                dy += 1
            }
            var c = 0
            while c < c8 {
                if let smp = sm { m[c] = SIMD8(tm[c].x, tm[c].y, smp[c].x, smp[c].y, a2[c], 0, 0, 0) }
                else { m[c] = SIMD8(tm[c].x, tm[c].y, a0[c], a1[c], a2[c], 0, 0, 0) }
                c += 1
            }
        }

        func distAdapted(_ tx: Int32, _ ty: Int32, _ sx: Int32, _ sy: Int32) -> Float {
            withUnsafeTemporaryAllocation(of: SIMD8<Float>.self, capacity: momCh) { m in
                let n = moments(tx, ty, sx, sy, m.baseAddress!)
                if n == 0 { return .infinity }
                return adaptedCost(adapt, Float(n), UnsafeBufferPointer(m), c8)
            }
        }

        func distAdaptedFull(_ k: Int, _ tx: Int32, _ ty: Int32, _ sx: Int32, _ sy: Int32) -> Float {
            withUnsafeTemporaryAllocation(of: SIMD8<Float>.self, capacity: momCh) { m in
                momentsFull(k, tx, ty, sx, sy, m.baseAddress!)
                return adaptedCost(adapt, Float(side * side), UnsafeBufferPointer(m), c8)
            }
        }

        /// Gain and bias per channel for the match `t → s` (identity without adaptation).
        func transform(_ tx: Int32, _ ty: Int32, _ k: Int, _ sx: Int32, _ sy: Int32, _ out: UnsafeMutablePointer<SIMD2<Float>>) {
            if adaptNone {
                for c in 0..<ch { out[c] = SIMD2(1, 0) }
                return
            }
            withUnsafeTemporaryAllocation(of: SIMD8<Float>.self, capacity: momCh) { mb in
                let m = mb.baseAddress!
                let n: Int
                if fullP[k] { momentsFull(k, tx, ty, sx, sy, m); n = side * side } else { n = moments(tx, ty, sx, sy, m) }
                for c in 0..<ch {
                    if n == 0 || c >= c8 { out[c] = SIMD2(1, 0) }
                    else { let (g, b) = fit(adapt, Float(n), m[c][0], m[c][1], m[c][2], m[c][3]); out[c] = SIMD2(g, b) }
                }
            }
        }

        /// One PatchMatch step at target `t` whose match is `(bx, by)` at cost `bc`: propagation
        /// from the neighbours visited just before it, then random search in exponentially shrinking
        /// windows (two numbers from `rng` per window).
        @inline(__always)
        func pmStep(_ tx: Int32, _ ty: Int32, _ k: Int, _ bx: inout Int32, _ by: inout Int32, _ bc: inout Float,
                    _ hasLeft: Bool, _ lx: Int32, _ ly: Int32, _ hasUp: Bool, _ ux: Int32, _ uy: Int32,
                    _ step: Int32, _ rng: inout Rng, _ searchRadius: Int32) {
            if hasLeft {
                let cx = lx + step, cy = ly
                if isValid(cx, cy) && (cx != bx || cy != by) {
                    let d = dist(tx, ty, k, cx, cy, bc)
                    if d < bc { bx = cx; by = cy; bc = d }
                }
            }
            if hasUp {
                let cx = ux, cy = uy + step
                if isValid(cx, cy) && (cx != bx || cy != by) {
                    let d = dist(tx, ty, k, cx, cy, bc)
                    if d < bc { bx = cx; by = cy; bc = d }
                }
            }
            var rad = searchRadius
            while rad >= 1 {
                let cx = bx &+ rng.range(-rad, rad)
                let cy = by &+ rng.range(-rad, rad)
                if isValid(cx, cy) && (cx != bx || cy != by) {
                    let d = dist(tx, ty, k, cx, cy, bc)
                    if d < bc { bx = cx; by = cy; bc = d }
                }
                rad /= 2
            }
        }

        /// One PatchMatch pass over all target rows, in bands of 16 grid rows: each band in raster
        /// order (backwards on odd passes), propagating within itself, its random numbers seeded by
        /// its index. The bands run in parallel.
        func patchmatch(_ nnf: UnsafeMutablePointer<SIMD2<Int32>>, _ cost: UnsafeMutablePointer<Float>, _ pass: Int, _ seed: UInt64, _ searchRadius: Int32) {
            let band = 16
            let tb = tbox
            let tw = tb.width
            if tw == 0 || tb.height == 0 { return }
            let reverse = pass % 2 == 1
            let step: Int32 = reverse ? -1 : 1
            var bands: [SIMD3<Int>] = []
            var y = tb.y0
            while y < tb.y1 {
                let bi = y / band
                let end = min((bi + 1) * band, tb.y1)
                bands.append(SIMD3(bi, y, end - y))
                y = end
            }
            let (nnS, coS) = (UnsafeSendable(nnf), UnsafeSendable(cost))
            let tg = targetsP
            let bandFn = { (j: Int) in
                let (bi, ys, rows) = (bands[j].x, bands[j].y, bands[j].z)
                if self.ctl.cancelled { return }
                let nn = nnS.value + (ys - tb.y0) * tw, co = coS.value + (ys - tb.y0) * tw
                var rng = Rng(seed ^ (UInt64(bi) &* 0x2545_F491_4F6C_DD1D) ^ (UInt64(pass) << 40))
                var ry = 0
                while ry < rows {
                    if self.ctl.cancelled { return }
                    let ly = reverse ? rows - 1 - ry : ry
                    let yy = ys + ly
                    var rx = 0
                    while rx < tw {
                        let lx = reverse ? tw - 1 - rx : rx
                        rx += 1
                        let li = ly * tw + lx
                        let k = (yy - tb.y0) * tw + lx
                        if !tg[k] { continue }
                        // Neighbours outside the target box hold no match: nothing to try.
                        let nx = lx - Int(step)
                        let hasLeft = nx >= 0 && nx < tw
                        let left = hasLeft ? nn[ly * tw + nx] : SIMD2<Int32>()
                        let nly = ly - Int(step)
                        let hasUp = nly >= 0 && nly < rows
                        let up = hasUp ? nn[nly * tw + lx] : SIMD2<Int32>()
                        var bx = nn[li].x, by = nn[li].y, bc = co[li]
                        self.pmStep(Int32(tb.x0 + lx), Int32(yy), k, &bx, &by, &bc, hasLeft, left.x, left.y, hasUp, up.x, up.y,
                                    step, &rng, searchRadius)
                        nn[li] = SIMD2(bx, by)
                        co[li] = bc
                    }
                    ry += 1
                }
            }
            if tb.area >= parMinPatches && bands.count > 1 { parallelFor(bands.count, bandFn) } else { for j in 0..<bands.count { bandFn(j) } }
        }

        /// Recompute every target's match cost (hole pixels change between iterations), and with
        /// colour adaptation the full target patches' own moments.
        func costs(_ nnfS: Store<SIMD2<Int32>>, _ costS: Store<Float>) throws {
            try ctl.check()
            if let g = gpu, try g.costs(self, nnfS, costS) { return try ctl.check() }
            let (nnf, cost) = (nnfS.ptr, costS.ptr)
            let (w, ch, r, tb, c8) = (self.w, self.ch, Int(self.r), self.tbox, self.c8)
            let side = 2 * r + 1
            let par = tb.area >= parMinPatches
            if let tm = tmom {
                let (ip, fp, tp) = (UnsafeSendable(UnsafePointer(img.ptr)), UnsafeSendable(full.ptr), UnsafeSendable(tm.ptr))
                let rowFn = { (ty: Int) in
                    for tx in 0..<tb.width where fp.value[ty * tb.width + tx] {
                        patchMoments(ip.value, w, ch, c8, side, tb.x0 + tx - r, tb.y0 + ty - r, tp.value + (ty * tb.width + tx) * c8)
                    }
                }
                if par { parallelChunks(tb.height, minChunk: 2) { rr in for ty in rr { rowFn(ty) } } } else { for ty in 0..<tb.height { rowFn(ty) } }
            }
            let (nS, cS, tg) = (UnsafeSendable(nnf), UnsafeSendable(cost), UnsafeSendable(targets.ptr))
            let rowC = { (ty: Int) in
                if self.ctl.cancelled { return }
                let y = tb.y0 + ty
                for tx in 0..<tb.width {
                    let k = ty * tb.width + tx
                    if tg.value[k] {
                        let s = nS.value[k]
                        cS.value[k] = self.dist(Int32(tb.x0 + tx), Int32(y), k, s.x, s.y, .infinity)
                    }
                }
            }
            if par { parallelChunks(tb.height, minChunk: 2) { rr in for ty in rr { rowC(ty) } } } else { for ty in 0..<tb.height { rowC(ty) } }
            try ctl.check()
        }

        /// σ² of the vote: the 75th percentile of the used targets' costs (at least 1e-6).
        func voteSigma2(_ cost: UnsafeMutablePointer<Float>) -> Float {
            var cs: [Float] = []
            for k in 0..<tbox.area where targets.ptr[k] && cost[k].isFinite { cs.append(cost[k]) }
            if cs.isEmpty { return 1 }
            let k = min(cs.count * 3 / 4, cs.count - 1)
            return Float.maximum(ToneKit.totalSorted(cs)[k], 1e-6)
        }

        /// Re-estimate hole pixels by a similarity-weighted vote of all overlapping patch matches
        /// (each copy adjusted by its gain and bias).
        func vote(_ nnfS: Store<SIMD2<Int32>>, _ costS: Store<Float>) throws {
            if ctl.cancelled { return }
            let (nnf, cost) = (nnfS.ptr, costS.ptr)
            let (w, h, ch, r) = (self.w, self.h, self.ch, Int(self.r))
            let (tb, hb) = (tbox, holeBox)
            let sigma2 = voteSigma2(cost)
            let adapted = !adapt.isNone
            let par = tb.area >= parMinPatches
            // A weight (zero for a target that doesn't vote) and its match's centre per target.
            let wt = Store(tb.area, Float(0), device: gpu?.device)
            let src = Store(tb.area, Int32(0), device: gpu?.device)
            for k in 0..<tb.area where targets.ptr[k] && cost[k].isFinite {
                wt.ptr[k] = Float.maximum(expf(-cost[k] / (2 * sigma2)), 1e-8)
                src.ptr[k] = nnf[k].y &* Int32(w) &+ nnf[k].x
            }
            var gb: Store<SIMD2<Float>>?
            if adapted {
                let g = Store(tb.area * ch, SIMD2<Float>(1, 0), device: gpu?.device)
                let (gS, nS, cS, tg) = (UnsafeSendable(g.ptr), UnsafeSendable(nnf), UnsafeSendable(cost), UnsafeSendable(targets.ptr))
                let rowT = { (ty: Int) in
                    if self.ctl.cancelled { return }
                    let y = tb.y0 + ty
                    for tx in 0..<tb.width {
                        let k = ty * tb.width + tx
                        if tg.value[k] && cS.value[k].isFinite {
                            let s = nS.value[k]
                            self.transform(Int32(tb.x0 + tx), Int32(y), k, s.x, s.y, gS.value + k * ch)
                        }
                    }
                }
                if let gp = gpu, try gp.transforms(self, nnfS, costS, into: g) {
                    // done on the GPU
                } else if par { parallelChunks(tb.height, minChunk: 2) { rr in for ty in rr { rowT(ty) } } } else { for ty in 0..<tb.height { rowT(ty) } }
                gb = g
            }
            if ctl.cancelled { return }
            if let g = gpu, try g.vote(self, wt, src, gb) { return }
            // The vote, into a buffer over the hole's bounds (every pixel reads the old pixels).
            var out = [Float](repeating: 0, count: hb.area * ch)
            var got = [Bool](repeating: false, count: hb.area)
            let img = UnsafeSendable(UnsafePointer(self.img.ptr)), pxp = UnsafeSendable(px.ptr)
            let (wtp, srcp) = (UnsafeSendable(wt.ptr), UnsafeSendable(src.ptr))
            let gbp = UnsafeSendable(gb?.ptr)
            out.withUnsafeMutableBufferPointer { ob in
                got.withUnsafeMutableBufferPointer { gotb in
                    let (oS, gS) = (UnsafeSendable(ob), UnsafeSendable(gotb))
                    let rowV = { (yy: Int) in
                        if self.ctl.cancelled { return }
                        var acc = [Float](repeating: 0, count: ch)
                        let y = hb.y0 + yy
                        for x in hb.x0..<hb.x1 where pxp.value[y * w + x] == .hole {
                            for c in 0..<ch { acc[c] = 0 }
                            var wsum: Float = 0
                            for ty in max(y - r, 0)...min(y + r, h - 1) {
                                let dy = ty - y
                                let krow = (ty - tb.y0) * tb.width
                                for tx in max(x - r, 0)...min(x + r, w - 1) {
                                    let k = krow + tx - tb.x0
                                    let wv = wtp.value[k]
                                    if wv == 0 { continue }
                                    // The pixel of the match's patch that lands here.
                                    let si = (Int(srcp.value[k]) - dy * w - (tx - x)) * ch
                                    for c in 0..<ch {
                                        var v = img.value[si + c]
                                        if let gbv = gbp.value { let t = gbv[k * ch + c]; v = t.x * v + t.y }
                                        acc[c] += v * wv
                                    }
                                    wsum += wv
                                }
                            }
                            if wsum > 0 {
                                let o = (yy * hb.width + (x - hb.x0)) * ch
                                for c in 0..<ch { oS.value[o + c] = acc[c] / wsum }
                                gS.value[yy * hb.width + (x - hb.x0)] = true
                            }
                        }
                    }
                    if hb.area >= parMinPatches { parallelChunks(hb.height, minChunk: 2) { rr in for yy in rr { rowV(yy) } } }
                    else { for yy in 0..<hb.height { rowV(yy) } }
                }
            }
            if ctl.cancelled { return }
            for yy in 0..<hb.height {
                for xx in 0..<hb.width where got[yy * hb.width + xx] {
                    let d = ((hb.y0 + yy) * w + hb.x0 + xx) * ch, s = (yy * hb.width + xx) * ch
                    for c in 0..<ch { self.img.ptr[d + c] = out[s + c] }
                }
            }
        }
    }
}
