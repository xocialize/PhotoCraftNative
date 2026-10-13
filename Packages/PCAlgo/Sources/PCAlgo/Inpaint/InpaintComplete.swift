// Port of photocraft-algo (crates/algo/src/inpaint.rs: onion_peel, known_sse, complete, complete_with, complete_masked, complete_masked_owned, complete_cow), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Content-aware completion (Wexler et al., TPAMI 2007, with PatchMatch, Barnes et al. 2009):
// coarse to fine over an image pyramid (down to where the hole is about four patches across);
// the coarsest level starts by filling the hole from its edge inwards (onion peel), every finer
// level from the coarser level's matches scaled up and voted with its own pixels; each EM
// iteration refreshes the match costs, runs PatchMatch and re-estimates the hole by a
// similarity-weighted vote. With `Adapt` the copies take Image Melding's gain and bias.

import Metal
import PCFoundation

extension InpaintKit {
    /// Fill the hole from its edge inwards, one ring at a time: each pixel takes the centre of the
    /// source patch that best matches what is already known around it (the first in `sources` of
    /// those that match best). A source's error stops being added up once it can only lose, and
    /// the search starts from where filled neighbours took theirs — the same picks as a plain
    /// scan in order (photocraft `onion_peel`).
    static func onionPeel(_ w: Int, _ h: Int, _ ch: Int, _ r: Int32, _ img: UnsafeMutablePointer<Float>, _ px: UnsafePointer<Px>,
                          _ hb: Bounds, _ sources: [(Int32, Int32)], _ ctl: Interrupt) throws {
        let none = UInt32.max
        var known = (0..<(w * h)).map { px[$0] == .known || px[$0] == .source }
        var index = [UInt32](repeating: none, count: w * h)
        for (j, s) in sources.enumerated() { index[Int(s.1) * w + Int(s.0)] = UInt32(j) }
        var took = [UInt32](repeating: none, count: w * h)
        let srcBase = sources.map { Int($0.1) * w + Int($0.0) }
        let srcPts = sources.map { SIMD2<Int32>($0.0, $0.1) }
        while true {
            try ctl.check()
            var front: [Int] = []
            for y in hb.y0..<hb.y1 {
                for x in hb.x0..<hb.x1 {
                    let i = y * w + x
                    if known[i] || px[i] != .hole { continue }
                    var edge = false
                    outer: for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            if nx >= 0 && ny >= 0 && nx < w && ny < h && known[ny * w + nx] { edge = true; break outer }
                        }
                    }
                    if edge { front.append(i) }
                }
            }
            if front.isEmpty { break }
            var vals = [(UInt32)](repeating: none, count: front.count)
            known.withUnsafeBufferPointer { kb in
                took.withUnsafeBufferPointer { tk in
                    index.withUnsafeBufferPointer { ix in
                        srcBase.withUnsafeBufferPointer { sb in
                            vals.withUnsafeMutableBufferPointer { vb in
                                let (kS, tS, iS, bS, vS) = (UnsafeSendable(kb), UnsafeSendable(tk), UnsafeSendable(ix), UnsafeSendable(sb), UnsafeSendable(vb))
                                let image = UnsafeSendable(UnsafePointer(img))
                                let one = { (f: Int) in
                                    vS.value[f] = bestSource(front[f], w, h, ch, r, image.value, kS.value, tS.value, iS.value, srcPts, bS.value, ctl)
                                }
                                if front.count * sources.count >= 4096 { parallelFor(front.count, one) } else { for f in 0..<front.count { one(f) } }
                            }
                        }
                    }
                }
            }
            try ctl.check()
            // Gather the picks before any pixel changes (every pick read the old pixels).
            var picked = [Float](repeating: 0, count: front.count * ch)
            for (f, j) in vals.enumerated() {
                let (sx, sy) = j == none ? (Int32(0), Int32(0)) : sources[Int(j)]
                let si = (Int(sy) * w + Int(sx)) * ch
                for c in 0..<ch { picked[f * ch + c] = img[si + c] }
            }
            for (f, i) in front.enumerated() {
                for c in 0..<ch { img[i * ch + c] = picked[f * ch + c] }
                known[i] = true
                took[i] = vals[f]
            }
        }
    }

    static let peelNeighbours: [SIMD2<Int32>] = [SIMD2(-1, -1), SIMD2(0, -1), SIMD2(1, -1), SIMD2(-1, 0), SIMD2(1, 0), SIMD2(-1, 1), SIMD2(0, 1), SIMD2(1, 1)]

    /// The best source of front pixel `i` (its place in `sources`, or `UInt32.max`).
    static func bestSource(_ i: Int, _ w: Int, _ h: Int, _ ch: Int, _ r: Int32, _ image: UnsafePointer<Float>,
                           _ known: UnsafeBufferPointer<Bool>, _ took: UnsafeBufferPointer<UInt32>, _ index: UnsafeBufferPointer<UInt32>,
                           _ sources: [SIMD2<Int32>], _ srcBase: UnsafeBufferPointer<Int>, _ ctl: Interrupt) -> UInt32 {
        let none = UInt32.max
        let x = Int32(i % w), y = Int32(i / w)
        // The known pixels of the target patch, in the plain scan's order.
        var offs: [Int] = []
        var tv: [Float] = []
        for dy in -r...r {
            for dx in -r...r {
                let tx = x + dx, ty = y + dy
                if tx >= 0 && ty >= 0 && Int(tx) < w && Int(ty) < h && known[Int(ty) * w + Int(tx)] {
                    let ti = (Int(ty) * w + Int(tx)) * ch
                    offs.append(Int(dy) * w + Int(dx))
                    for c in 0..<ch { tv.append(image[ti + c]) }
                }
            }
        }
        if offs.isEmpty { return none }
        let nf = Float(offs.count)
        var bv = Float.infinity, bj = Int.max, worse = Float.infinity, equal = Float.infinity
        offs.withUnsafeBufferPointer { ob in
            tv.withUnsafeBufferPointer { tb in
                /// Source j's sum (NaN once it reaches its limit: it can't win).
                let (op, tvp, np) = (ob.baseAddress!, tb.baseAddress!, ob.count)
                @inline(__always) func sse(_ base: Int, _ limit: Float) -> Float {
                    var e: Float = 0
                    var p = 0
                    while p < np {
                        let si = (base + op[p]) * ch
                        let tp = p * ch
                        var c = 0
                        while c < ch { let d = tvp[tp + c] - image[si + c]; e += d * d; c += 1 }
                        if e >= limit { return .nan }
                        p += 1
                    }
                    return e
                }
                @inline(__always) func consider(_ j: Int) {
                    if j >= sources.count { return }
                    // A tie loses to an earlier source.
                    let limit = j > bj ? equal : worse
                    // NaN: gave up at the limit (or a NaN sum) — never adopted, as in photocraft.
                    let e = sse(srcBase[j], limit)
                    let v = e / nf
                    if v < .infinity && (v < bv || (v == bv && j < bj)) {
                        bv = v; bj = j
                        worse = leastSum(v, nf, true); equal = leastSum(v, nf, false)
                    }
                }
                // A close bound early: where the filled neighbours' sources point.
                for nbr in peelNeighbours {
                    let (dx, dy) = (nbr.x, nbr.y)
                    let qx = x + dx, qy = y + dy
                    if qx < 0 || qy < 0 || Int(qx) >= w || Int(qy) >= h { continue }
                    let t = took[Int(qy) * w + Int(qx)]
                    if t == none || Int(t) >= sources.count { continue }
                    let sp = sources[Int(t)]
                    let cx = sp.x - dx, cy = sp.y - dy
                    if cx >= 0 && cy >= 0 && Int(cx) < w && Int(cy) < h && index[Int(cy) * w + Int(cx)] != none {
                        consider(Int(index[Int(cy) * w + Int(cx)]))
                    }
                }
                if bj == Int.max { for j in stride(from: 0, to: sources.count, by: 16) { consider(j) } }
                // The scan in order, each source against its limit from the best before it.
                for j in 0..<sources.count {
                    if j % 4096 == 0 && j > 0 && ctl.cancelled { break }
                    consider(j)
                }
            }
        }
        return bj == Int.max ? none : UInt32(bj)
    }

    // MARK: Completion

    /// Content-aware completion of `hole`, copying from any pixel outside it (photocraft
    /// `complete`). nil when there is no fully-known patch to copy from (fall back to
    /// `Poisson.membraneFill`). `on:` picks where the per-target costs, transforms and the vote run
    /// (bit-identical either way); PatchMatch and the onion peel run on the CPU.
    public static func complete(width w: Int, height h: Int, channels ch: Int, image: [Float], hole: [Bool],
                                params p: CompleteParams = CompleteParams(), on backend: Backend = .cpu) -> [Float]? {
        (try? completeWith(width: w, height: h, channels: ch, image: image, hole: hole, params: p, interrupt: .none, on: backend)) ?? nil
    }

    /// `complete` that can be cancelled and reports progress (by pyramid level).
    public static func completeWith(width w: Int, height h: Int, channels ch: Int, image: [Float], hole: [Bool], params p: CompleteParams,
                                    interrupt ctl: Interrupt, on backend: Backend = .cpu) throws -> [Float]? {
        precondition(hole.count == w * h)
        return try completeMasked(width: w, height: h, channels: ch, image: image, roles: hole.map { $0 ? .hole : .source },
                                  params: p, interrupt: ctl, on: backend)
    }

    /// `completeWith` with every pixel's role given (`Px`): the hole, the context, what may be
    /// copied, and what isn't image at all (photocraft `complete_masked`).
    public static func completeMasked(width w: Int, height h: Int, channels ch: Int, image: [Float], roles px: [Px], params p: CompleteParams,
                                      interrupt ctl: Interrupt = .none, on backend: Backend = .cpu) throws -> [Float]? {
        try completeLevels(w, h, ch, image, px, p, ctl, backend)
    }

    /// `completeMasked` filling `image` itself (only the hole changes); false, `image` untouched,
    /// when there is nothing to copy from (photocraft `complete_masked_owned`).
    public static func completeMaskedOwned(width w: Int, height h: Int, channels ch: Int, image: inout [Float], roles px: [Px],
                                           params p: CompleteParams, interrupt ctl: Interrupt = .none, on backend: Backend = .cpu) throws -> Bool {
        guard let out = try completeLevels(w, h, ch, image, px, p, ctl, backend) else { return false }
        image = out
        return true
    }

    static func completeLevels(_ w: Int, _ h: Int, _ ch: Int, _ img0: [Float], _ px0: [Px], _ p: CompleteParams, _ ctl: Interrupt,
                               _ backend: Backend) throws -> [Float]? {
        precondition(img0.count == w * h * ch && px0.count == w * h)
        guard let hb0 = holeBounds(w, h, px0) else { return img0 }
        if ch == 0 { return [] }
        let gpuAll: InpaintGPU?
        switch backend {
        case .cpu: gpuAll = nil
        case .gpu: gpuAll = try InpaintGPU.make(force: true)
        case .auto: gpuAll = try? InpaintGPU.make(force: false)
        }
        let r = max(p.patchRadius, 1)
        let psz = 2 * r + 1
        // Pyramid: shrink until the hole is about four patches across.
        var levels = [Level(w: w, h: h, img: img0, px: px0)]
        var boxes = [hb0]
        var ext = max(hb0.width, hb0.height)
        var exts = [ext]
        while let l = levels.last {
            try ctl.check()
            if ext <= 4 * psz || l.w / 2 < 3 * psz || l.h / 2 < 3 * psz { break }
            levels.append(downsample(l, ch))
            boxes.append(boxes[boxes.count - 1].half)
            ext = (ext + 1) / 2
            exts.append(ext)
        }
        let nlev = levels.count
        var prev: Coarser?
        let totalPx = levels.reduce(0) { $0 + $1.w * $1.h }
        var donePx = 0
        let ri = Int32(r)
        for li in stride(from: nlev - 1, through: 0, by: -1) {
            try ctl.check()
            let level = levels[li]
            levels[li] = Level(w: 0, h: 0, img: [], px: [])
            let (lw, lh) = (level.w, level.h)
            let hb = boxes[li]
            let tb = hb.grow(r, lw, lh)
            let valid = try validSources(lw, lh, r, level.px, ctl)
            let sources = Sources(valid, lw)
            // Nothing to copy from at the finest level: the caller falls back.
            if li == 0 && sources.count == 0 { return nil }
            // The GPU where it pays (`.auto`: big target boxes) or where asked.
            let gpu: InpaintGPU? = gpuAll.flatMap { g in g.force || tb.area >= InpaintGPU.minTargets ? g : nil }
            let limg = Store(level.img, device: gpu?.device)
            let lpx = Store(level.px, device: gpu?.device)
            let targets = targetsAround(lw, r, level.px, hb, tb)
            try ctl.check()
            // Initialise the hole: at the coarsest level peeled from its edge inwards (or a membrane
            // where nothing can be copied), else the coarser level's pixels.
            let coarser = prev
            prev = nil
            if let c = coarser {
                let (pw, ph) = (c.w, c.h)
                for y in hb.y0..<hb.y1 {
                    for x in hb.x0..<hb.x1 where level.px[y * lw + x] == .hole {
                        let sx = min(x / 2, pw - 1), sy = min(y / 2, ph - 1)
                        let d = (y * lw + x) * ch, s = (sy * pw + sx) * ch
                        for k in 0..<ch { limg.ptr[d + k] = c.img[s + k] }
                    }
                }
            } else if sources.count > 0 {
                try onionPeel(lw, lh, ch, ri, limg.ptr, lpx.ptr, hb, sources.all(valid, lw), ctl)
            } else {
                let unknown = level.px.map { $0 == .hole || $0 == .void }
                let m = Poisson.membraneFill(width: lw, height: lh, channels: ch, image: limg.array, hole: unknown)
                for (i, k) in level.px.enumerated() where k == .hole { for c in 0..<ch { limg.ptr[i * ch + c] = m[i * ch + c] } }
            }
            if sources.count == 0 {
                prev = Coarser(w: lw, h: lh, img: limg.array, field: [], tbox: tb)
                continue
            }
            let refineOnly = li + 1 < nlev && exts[li] > p.refineExtent
            let nTargets = targets.reduce(0) { $0 + ($1 ? 1 : 0) }
            // Source moments are worth keeping when there are few sources for the matches tried.
            let (mul, ovf) = nTargets.multipliedReportingOverflow(by: refineOnly ? 4 : 64)
            let keepSourceMoments = lw * lh <= sourceMomentsMax && sources.count <= (ovf ? Int.max : mul)
            let solver = Solver(w: lw, h: lh, ch: ch, r: ri, img: limg, px: lpx, valid: valid, holeBox: hb, tbox: tb,
                                targets: targets, adapt: p.adapt, ctl: ctl, gpu: gpu)
            solver.prepare(keepSourceMoments)
            try ctl.check()
            // NNF init: the coarser level's matches scaled up where they land on a valid source,
            // random otherwise.
            var rng = Rng(p.seed ^ (UInt64(li) << 20))
            let tw = tb.width
            let nnf = Store(tb.area, SIMD2<Int32>(0, 0), device: gpu?.device)
            var upsampled = false
            for y in tb.y0..<tb.y1 {
                if y % 32 == 0 { try ctl.check() }
                for x in tb.x0..<tb.x1 {
                    let k = (y - tb.y0) * tw + (x - tb.x0)
                    if !targets[k] { continue }
                    var cand: (Int32, Int32)?
                    if let c = coarser, !c.field.isEmpty {
                        let cx = min(x / 2, c.w - 1), cy = min(y / 2, c.h - 1)
                        let (sx, sy) = c.fieldAt(cx, cy)
                        if sx != .min {
                            // The same displacement, twice as long.
                            let cc = (Int32(x) + 2 * (sx - Int32(cx)), Int32(y) + 2 * (sy - Int32(cy)))
                            if solver.isValid(cc.0, cc.1) { cand = cc }
                        }
                    }
                    upsampled = upsampled || cand != nil
                    let m = cand ?? sources.nth(Int(rng.next() % UInt64(sources.count)), valid, lw)
                    nnf.ptr[k] = SIMD2(m.0, m.1)
                }
            }
            let cost = Store(tb.area, Float.infinity, device: gpu?.device)
            // A finer level starts from the coarse matches voted with its own (sharp) pixels.
            if upsampled {
                try solver.costs(nnf, cost)
                try solver.vote(nnf, cost)
            }
            let em: Int
            if li + 1 == nlev { em = p.emIters } else if refineOnly { em = 1 } else { em = max(p.emIters >> (nlev - 1 - li), p.minEmIters) }
            let pmIters = refineOnly ? 1 : p.pmIters
            let fullSearch = Int32(max(lw, lh))
            for it in 0..<em {
                // Costs change as hole pixels are re-estimated: refresh before each PatchMatch.
                try solver.costs(nnf, cost)
                let radius: Int32
                if refineOnly { radius = 2 } else if li + 1 == nlev || it == 0 { radius = fullSearch } else { radius = min(Int32(4 * psz), fullSearch) }
                for pass in 0..<pmIters {
                    try ctl.check()
                    solver.patchmatch(nnf.ptr, cost.ptr, pass + it * pmIters, p.seed &+ UInt64(li * 1000 + it), radius)
                }
                try ctl.check()
                try solver.vote(nnf, cost)
                try ctl.check()
            }
            try ctl.check()
            // Keep the match field for the next level (none after the last).
            var field: [(Int32, Int32)] = []
            if li != 0 { field = (0..<tb.area).map { targets[$0] ? (nnf.ptr[$0].x, nnf.ptr[$0].y) : (.min, .min) } }
            donePx += lw * lh
            ctl.report(Float(donePx) / Float(max(totalPx, 1)))
            prev = Coarser(w: lw, h: lh, img: limg.array, field: field, tbox: tb)
        }
        return prev?.img ?? []
    }
}
