// Port of photocraft-algo (crates/algo/src/pyramid.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Multiresolution blending for Edit › Auto-Blend Layers (P. J. Burt, E. H. Adelson, "A
// Multiresolution Spline With Application to Image Mosaics", ACM TOG 1983): Laplacian pyramids of
// the images, Gaussian pyramids of the weights, a blend per level, collapsed. `fuseStack` is the
// focus stack's merge (Adelson et al. 1984's multifocus composite with W. Wang, F. Chang's
// maximum-region-energy and deviation/entropy rules, Journal of Computers 2011) plus halo control.
//
// Buffers are interleaved `w × h × ch` normalised floats of any colour model and depth. This file
// is the CPU reference (photocraft's arithmetic, operation for operation); `PyramidGPU.swift` is
// the Metal path, which runs the same per-element arithmetic and matches it bit for bit except
// where halo control's `exp`/`ln` weights enter (a few ulp).

import Foundation
import PCFoundation

/// Laplacian / Gaussian pyramids, multiresolution blending and focus-stack fusion (photocraft
/// `pyramid`). Every operation takes a `Backend` (`.auto` runs Metal when available).
public enum Pyramid {
    /// One pyramid level: `w × h` pixels of `ch` interleaved channels (the channel count is the
    /// caller's).
    public struct Level: Hashable, Sendable {
        public var w: Int
        public var h: Int
        public var px: [Float]
        public init(w: Int, h: Int, px: [Float]) { self.w = w; self.h = h; self.px = px }
    }

    /// The 5-tap binomial kernel.
    static let k: [Float] = [1.0 / 16.0, 4.0 / 16.0, 6.0 / 16.0, 4.0 / 16.0, 1.0 / 16.0]

    /// Focus-stack fusion settings for `fuseStack` (photocraft `StackFusion`).
    public struct StackFusion: Hashable, Sendable, Codable {
        /// Region-energy window radius for the band-pass levels: 1 = Wang & Chang's 3×3 binomial
        /// window; 0 = the per-node |L| of Adelson et al.
        public var energyRadius: Int
        /// Halo control hardness: 0 = off (every level picks its own winner); otherwise the levels
        /// coarser than `guide` are the mean of the images weighed by the guide's region energy to
        /// this power, capped at `haloMax`.
        public var halo: Float
        /// The guide level for halo control (0 = the finest band-pass level), clamped to the last
        /// band-pass level.
        public var guide: Int
        /// Pyramid levels, the residual included; nil = `stackLevels`.
        public var levels: Int?

        public init(energyRadius: Int = 1, halo: Float = 2, guide: Int = 2, levels: Int? = nil) {
            self.energyRadius = energyRadius; self.halo = halo; self.guide = guide; self.levels = levels
        }
    }

    /// Largest useful halo hardness (photocraft `HALO_MAX`).
    public static let haloMax: Float = 8
    /// Reference energy the halo weights are relative to.
    static let haloRef: Float = 1e-4
    /// Floor added to the energy before weighing.
    static let haloFloor: Float = 1e-8
    /// Coverage below which an image has no say at a pixel.
    static let covered: Float = 0.5
    /// The energy of an image where it does not cover the pixel.
    static let noEnergy: Float = -1

    // MARK: - REDUCE / EXPAND

    /// 5-tap binomial filter + decimation by two (Burt & Adelson's REDUCE).
    public static func reduce(_ l: Level, channels ch: Int) -> Level {
        let w = (l.w + 1) / 2, h = (l.h + 1) / 2
        var tmp = [Float](repeating: 0, count: w * l.h * ch)
        let lw = l.w, lh = l.h
        if w > 0 && lh > 0 {
            l.px.withUnsafeBufferPointer { s in
                tmp.withUnsafeMutableBufferPointer { t in
                    let sp = UnsafeSendable(s.baseAddress!), tp = UnsafeSendable(t.baseAddress!)
                    PhotoKit.parRows(lh) { y in
                        let s = sp.value, row = tp.value + y * w * ch
                        for x in 0..<w {
                            for kk in 0..<5 {
                                let wt = k[kk]
                                let sx = min(max(2 * x + kk - 2, 0), lw - 1)
                                let src = s + (y * lw + sx) * ch
                                for c in 0..<ch { row[x * ch + c] += wt * src[c] }
                            }
                        }
                    }
                }
            }
        }
        var px = [Float](repeating: 0, count: w * h * ch)
        if w > 0 && h > 0 {
            tmp.withUnsafeBufferPointer { t in
                px.withUnsafeMutableBufferPointer { p in
                    let tp = UnsafeSendable(t.baseAddress!), pp = UnsafeSendable(p.baseAddress!)
                    PhotoKit.parRows(h) { y in
                        let row = pp.value + y * w * ch
                        for kk in 0..<5 {
                            let wt = k[kk]
                            let sy = min(max(2 * y + kk - 2, 0), lh - 1)
                            let src = tp.value + sy * w * ch
                            for i in 0..<(w * ch) { row[i] += wt * src[i] }
                        }
                    }
                }
            }
        }
        return Level(w: w, h: h, px: px)
    }

    /// Upsamples `l` to `w × h` (EXPAND: zero insertion + the same filter, ×4 gain).
    public static func expand(_ l: Level, channels ch: Int, width w: Int, height h: Int) -> [Float] {
        let lw = l.w, lh = l.h
        var tmp = [Float](repeating: 0, count: w * lh * ch)
        if w > 0 && lh > 0 {
            l.px.withUnsafeBufferPointer { s in
                tmp.withUnsafeMutableBufferPointer { t in
                    let sp = UnsafeSendable(s.baseAddress!), tp = UnsafeSendable(t.baseAddress!)
                    PhotoKit.parRows(lh) { y in
                        let row = tp.value + y * w * ch
                        for x in 0..<w {
                            for kk in 0..<5 {
                                let t = x + kk - 2
                                if t & 1 != 0 { continue }
                                let sx = min(max(t / 2, 0), lw - 1)
                                let wt = 2 * k[kk]
                                let src = sp.value + (y * lw + sx) * ch
                                for c in 0..<ch { row[x * ch + c] += wt * src[c] }
                            }
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: w * h * ch)
        if w > 0 && h > 0 {
            tmp.withUnsafeBufferPointer { t in
                out.withUnsafeMutableBufferPointer { o in
                    let tp = UnsafeSendable(t.baseAddress!), op = UnsafeSendable(o.baseAddress!)
                    PhotoKit.parRows(h) { y in
                        let row = op.value + y * w * ch
                        for kk in 0..<5 {
                            let t = y + kk - 2
                            if t & 1 != 0 { continue }
                            let sy = min(max(t / 2, 0), lh - 1)
                            let wt = 2 * k[kk]
                            let src = tp.value + sy * w * ch
                            for i in 0..<(w * ch) { row[i] += wt * src[i] }
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - Pyramids

    /// Gaussian pyramid with `levels` levels (level 0 = the input).
    public static func gaussian(width w: Int, height h: Int, channels ch: Int, _ px: [Float], levels: Int) -> [Level] {
        var out = [Level(w: w, h: h, px: px)]
        while out.count < max(levels, 1) {
            let last = out[out.count - 1]
            if last.w <= 1 && last.h <= 1 { break }
            out.append(reduce(last, channels: ch))
        }
        return out
    }

    /// Laplacian pyramid: band-pass levels, the last level is the low-pass residual.
    public static func laplacian(width w: Int, height h: Int, channels ch: Int, _ px: [Float], levels: Int) -> [Level] {
        let g = gaussian(width: w, height: h, channels: ch, px, levels: levels)
        var out: [Level] = []
        out.reserveCapacity(g.count)
        for i in 0..<g.count {
            if i + 1 == g.count {
                out.append(g[i])
            } else {
                let up = expand(g[i + 1], channels: ch, width: g[i].w, height: g[i].h)
                out.append(Level(w: g[i].w, h: g[i].h, px: zipMap(g[i].px, up, -)))
            }
        }
        return out
    }

    /// Rebuilds an image from its Laplacian pyramid.
    public static func collapse(_ pyr: [Level], channels ch: Int) -> [Float] {
        guard var cur = pyr.last else { return [] }
        for l in pyr.dropLast().reversed() {
            let up = expand(cur, channels: ch, width: l.w, height: l.h)
            cur = Level(w: l.w, h: l.h, px: zipMap(l.px, up, +))
        }
        return cur.px
    }

    /// `gaussian` on `backend` (the Metal path is bit-identical).
    public static func gaussian(width w: Int, height h: Int, channels ch: Int, _ px: [Float], levels: Int, on backend: Backend) throws -> [Level] {
        try PhotoKit.run(backend, "Pyramid.gaussian", fits: PhotoKit.gpuFits(w, h, ch),
                         gpu: { try PyramidGPU.gaussian(w, h, ch, px, levels) },
                         cpu: { gaussian(width: w, height: h, channels: ch, px, levels: levels) })
    }

    /// `laplacian` on `backend` (the Metal path is bit-identical).
    public static func laplacian(width w: Int, height h: Int, channels ch: Int, _ px: [Float], levels: Int, on backend: Backend) throws -> [Level] {
        try PhotoKit.run(backend, "Pyramid.laplacian", fits: PhotoKit.gpuFits(w, h, ch),
                         gpu: { try PyramidGPU.laplacian(w, h, ch, px, levels) },
                         cpu: { laplacian(width: w, height: h, channels: ch, px, levels: levels) })
    }

    /// `collapse` on `backend` (the Metal path is bit-identical).
    public static func collapse(_ pyr: [Level], channels ch: Int, on backend: Backend) throws -> [Float] {
        let fits = pyr.first.map { PhotoKit.gpuFits($0.w, $0.h, ch) } ?? false
        return try PhotoKit.run(backend, "Pyramid.collapse", fits: fits, gpu: { try PyramidGPU.collapse(pyr, ch) },
                                cpu: { collapse(pyr, channels: ch) })
    }

    /// Number of levels so the coarsest level is a few pixels across.
    public static func autoLevels(width w: Int, height h: Int) -> Int {
        var n = 1, s = min(w, h)
        while s > 8 && n < 10 { s /= 2; n += 1 }
        return n
    }

    @inline(__always)
    static func zipMap(_ a: [Float], _ b: [Float], _ f: (Float, Float) -> Float) -> [Float] {
        let n = min(a.count, b.count)
        return [Float](unsafeUninitializedCapacity: n) { d, cnt in
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    for i in 0..<n { d[i] = f(a[i], b[i]) }
                }
            }
            cnt = n
        }
    }

    // MARK: - Blend

    /// Blends `images` with per-pixel `weights` (any non-negative values; normalised per level),
    /// clamped to 0…1 (photocraft `blend`).
    public static func blend(width w: Int, height h: Int, channels ch: Int, images: [[Float]], weights: [[Float]], levels: Int,
                             on backend: Backend = .auto) throws -> [Float] {
        precondition(images.count == weights.count, "one weight map per image")
        return try PhotoKit.run(backend, "Pyramid.blend \(w)×\(h)", fits: PhotoKit.gpuFits(w, h, ch),
                                gpu: { try PyramidGPU.blend(w, h, ch, images, weights, max(levels, 1)) },
                                cpu: { blendCPU(w, h, ch, images, weights, levels) })
    }

    static func blendCPU(_ w: Int, _ h: Int, _ ch: Int, _ images: [[Float]], _ weights: [[Float]], _ levels0: Int) -> [Float] {
        let levels = max(levels0, 1)
        var acc: [Level]? = nil
        var wsum: [Level]? = nil
        for (img, wt) in zip(images, weights) {
            let lp = laplacian(width: w, height: h, channels: ch, img, levels: levels)
            let gp = gaussian(width: w, height: h, channels: 1, wt, levels: levels)
            if acc == nil { acc = lp.map { Level(w: $0.w, h: $0.h, px: [Float](repeating: 0, count: $0.px.count)) } }
            if wsum == nil { wsum = gp.map { Level(w: $0.w, h: $0.h, px: [Float](repeating: 0, count: $0.px.count)) } }
            for (li, (l, g)) in zip(lp, gp).enumerated() {
                let n = l.w * l.h
                acc![li].px.withUnsafeMutableBufferPointer { a in
                    wsum![li].px.withUnsafeMutableBufferPointer { s in
                        l.px.withUnsafeBufferPointer { lpx in
                            g.px.withUnsafeBufferPointer { gpx in
                                for i in 0..<n {
                                    let k = gpx[i]
                                    s[i] += k
                                    for c in 0..<ch { a[i * ch + c] += k * lpx[i * ch + c] }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard var a = acc, let s = wsum else { return [Float](repeating: 0, count: w * h * ch) }
        for li in 0..<min(a.count, s.count) {
            let n = a[li].w * a[li].h
            a[li].px.withUnsafeMutableBufferPointer { ap in
                s[li].px.withUnsafeBufferPointer { sp in
                    for i in 0..<n {
                        let k = sp[i]
                        for c in 0..<ch { ap[i * ch + c] = k > 1e-6 ? ap[i * ch + c] / k : 0 }
                    }
                }
            }
        }
        return collapse(a, channels: ch).map(PhotoKit.clamp01)
    }

    // MARK: - Focus-stack fusion

    /// Levels for `fuseStack`: as many band-pass levels as keep the residual's short side ≥ 32 px.
    public static func stackLevels(width w: Int, height h: Int) -> Int {
        var n = 1, s = min(w, h)
        while (s + 1) / 2 >= 32 && n < 10 { s = (s + 1) / 2; n += 1 }
        return n
    }

    /// `((re + floor) / ref)^p`, its exponent clamped to ±60 (photocraft `halo_weight`).
    static func haloWeight(_ re: Float, _ p: Float) -> Float {
        expf(PhotoKit.clamp(p * logf((PCAMath.pos(re) + haloFloor) / haloRef), -60, 60))
    }

    /// Binomial window weights of radius `r` (row 2r of Pascal's triangle / 4^r).
    static func binomial(_ r: Int) -> [Float] {
        let n = 2 * r + 1
        var row = [UInt64](repeating: 1, count: n)
        if n > 1 {
            for i in 1..<n {
                var j = i - 1
                while j >= 1 { row[j] = row[j] &+ row[j - 1]; j -= 1 }
            }
        }
        let s = Float(row.reduce(0, &+))
        return row.map { Float($0) / s }
    }

    /// Separable weighted window sum of a plane (`wt` of odd length, clamped borders).
    static func windowSum(_ w: Int, _ h: Int, _ src: [Float], _ wt: [Float]) -> [Float] {
        let r = wt.count / 2
        if r == 0 || w == 0 || h == 0 { return src }
        var tmp = [Float](repeating: 0, count: w * h)
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                let sp = UnsafeSendable(s.baseAddress!), tp = UnsafeSendable(t.baseAddress!)
                PhotoKit.parRows(h) { y in
                    let s = sp.value + y * w, row = tp.value + y * w
                    for x in 0..<w {
                        var o: Float = -0.0
                        for (t, kv) in wt.enumerated() { o += kv * s[min(max(x + t - r, 0), w - 1)] }
                        row[x] = o
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                let tp = UnsafeSendable(t.baseAddress!), op = UnsafeSendable(o.baseAddress!)
                PhotoKit.parRows(h) { y in
                    let row = op.value + y * w
                    for (t, kv) in wt.enumerated() {
                        let sy = min(max(y + t - r, 0), h - 1)
                        let src = tp.value + sy * w
                        for x in 0..<w { row[x] += kv * src[x] }
                    }
                }
            }
        }
        return out
    }

    /// Region energy of a band-pass luminance level: the window sum of L² (Wang & Chang eq. 13);
    /// `noEnergy` where the image's coverage is below `covered`.
    static func regionEnergy(_ l: Level, _ cover: Level, _ win: [Float]) -> [Float] {
        let e = l.px.map { $0 * $0 }
        var re = windowSum(l.w, l.h, e, win)
        for i in 0..<min(re.count, cover.px.count) where cover.px[i] < covered { re[i] = noEnergy }
        return re
    }

    /// The `p · ln p` terms of the local entropy for 1…25 samples of a 5×5 window in one bin.
    static let entropyTerms: [Float] = {
        let invN: Float = 1.0 / 25.0
        return (0...25).map { n -> Float in
            let p = Float(n) * invN
            return p * logf(p)
        }
    }()

    /// Local deviation (Wang & Chang eq. 10) and local entropy (eq. 11, 256 gray levels) of a plane
    /// over a 5×5 window, clamped borders.
    static func deviationEntropy(_ w: Int, _ h: Int, _ y: [Float]) -> ([Float], [Float]) {
        let r = 2, bins = 256
        let n = (2 * r + 1) * (2 * r + 1)
        let invN: Float = 1.0 / Float(n)
        var dev = [Float](repeating: 0, count: w * h), ent = [Float](repeating: 0, count: w * h)
        if w == 0 || h == 0 { return (dev, ent) }
        y.withUnsafeBufferPointer { yb in
            dev.withUnsafeMutableBufferPointer { db in
                ent.withUnsafeMutableBufferPointer { eb in
                    let yp = UnsafeSendable(yb.baseAddress!), dp = UnsafeSendable(db.baseAddress!), ep = UnsafeSendable(eb.baseAddress!)
                    PhotoKit.parRows(h) { i in
                        var hist = [UInt32](repeating: 0, count: bins)
                        var touched: [Int] = []
                        touched.reserveCapacity(n)
                        let y = yp.value
                        for j in 0..<w {
                            var s: Float = 0, s2: Float = 0
                            touched.removeAll(keepingCapacity: true)
                            for dy in 0...(2 * r) {
                                let yy = min(max(i + dy - r, 0), h - 1)
                                for dx in 0...(2 * r) {
                                    let v = y[yy * w + min(max(j + dx - r, 0), w - 1)]
                                    s += v
                                    s2 += v * v
                                    let q = min(PhotoKit.usize(PhotoKit.clamp01(v) * Float(bins - 1) + 0.5), bins - 1)
                                    if hist[q] == 0 { touched.append(q) }
                                    hist[q] += 1
                                }
                            }
                            let mean = s * invN
                            dp.value[i * w + j] = PCAMath.pos(s2 * invN - mean * mean)
                            var e: Float = 0
                            for q in touched {
                                let p = Float(hist[q]) * invN
                                e -= p * logf(p)
                                hist[q] = 0
                            }
                            ep.value[i * w + j] = e
                        }
                    }
                }
            }
        }
        return (dev, ent)
    }

    /// One image's residual (low-pass) level, with its luminance and coverage at that level.
    struct Residual {
        var px: Level
        var luma: [Float]
        var cover: [Float]
    }

    /// Fuses the residuals by the generalised (Pareto) region-information rule (Wang & Chang eq. 12).
    static func fuseResiduals(_ tops: [Residual], _ ch: Int) -> Level {
        guard let t0 = tops.first else { return Level(w: 0, h: 0, px: []) }
        let w = t0.px.w, h = t0.px.h, n = tops.count
        let measures = PhotoKit.parMap(n) { deviationEntropy(w, h, tops[$0].luma) }
        var out = [Float](repeating: 0, count: w * h * ch)
        var keep = [Bool](repeating: false, count: n)
        for i in 0..<(w * h) {
            let anyCover = tops.contains { $0.cover[i] >= covered }
            func eligible(_ a: Int) -> Bool { !anyCover || tops[a].cover[i] >= covered }
            var kept = 0
            for a in 0..<n {
                let da = measures[a].0[i], ea = measures[a].1[i]
                let dominated = eligible(a) && (0..<n).contains { b in
                    let db = measures[b].0[i], eb = measures[b].1[i]
                    return b != a && eligible(b) && db >= da && eb >= ea && (db > da || eb > ea)
                }
                keep[a] = eligible(a) && !dominated
                kept += keep[a] ? 1 : 0
            }
            let inv = 1.0 / Float(max(kept, 1))
            for (t, k) in zip(tops, keep) where k {
                for c in 0..<ch { out[i * ch + c] += t.px.px[i * ch + c] * inv }
            }
        }
        return Level(w: w, h: h, px: out)
    }

    /// Halo control: folds the levels coarser than the guide `g` as Σ w·L and Σ w, the guide's
    /// weights REDUCEd to each level's size. `src` nil scales the first image's levels in place.
    static func foldHalo(_ acc: inout [Level], _ wsum: inout [[Float]], _ src: [Level]?, _ g: Int, _ wgt0: Level, _ ch: Int) {
        var wgt = wgt0
        if g + 1 >= acc.count { return }
        for li in (g + 1)..<acc.count {
            wgt = reduce(wgt, channels: 1)
            let aw = acc[li].w, ah = acc[li].h
            let wp = wgt.px
            if let src {
                if li - g - 1 < wsum.count {
                    for i in 0..<min(wsum[li - g - 1].count, wp.count) { wsum[li - g - 1][i] += wp[i] }
                }
                let sp = src[li].px
                acc[li].px.withUnsafeMutableBufferPointer { a in
                    sp.withUnsafeBufferPointer { s in
                        wp.withUnsafeBufferPointer { k in
                            let ap = UnsafeSendable(a.baseAddress!), spp = UnsafeSendable(s.baseAddress!), kp = UnsafeSendable(k.baseAddress!)
                            PhotoKit.parRows(ah) { y in
                                for x in 0..<aw {
                                    let i = y * aw + x, kv = kp.value[i]
                                    for c in 0..<ch { ap.value[i * ch + c] += kv * spp.value[i * ch + c] }
                                }
                            }
                        }
                    }
                }
            } else {
                acc[li].px.withUnsafeMutableBufferPointer { a in
                    wp.withUnsafeBufferPointer { k in
                        let ap = UnsafeSendable(a.baseAddress!), kp = UnsafeSendable(k.baseAddress!)
                        PhotoKit.parRows(ah) { y in
                            for x in 0..<aw {
                                let i = y * aw + x, kv = kp.value[i]
                                for c in 0..<ch { ap.value[i * ch + c] *= kv }
                            }
                        }
                    }
                }
                wsum.append(wp)
            }
        }
    }

    /// The pyramid depth `fuseStack` actually uses (REDUCE stops at 1 × 1).
    static func fuseLevels(_ w: Int, _ h: Int, _ p: StackFusion) -> Int {
        let want = max(p.levels ?? stackLevels(width: w, height: h), 1)
        var n = 1, a = w, b = h
        while (a > 1 || b > 1) && n < want { a = (a + 1) / 2; b = (b + 1) / 2; n += 1 }
        return n
    }

    /// Halo control's guide level and hardness, nil when off.
    static func haloSetting(_ bands: Int, _ p: StackFusion) -> (g: Int, hard: Float)? {
        (bands > 0 && p.halo > 0) ? (min(max(p.guide, 0), bands - 1), min(p.halo, haloMax)) : nil
    }

    /// Multifocus composite of `images` (interleaved `w × h × ch`; `luma[k]` is image k's
    /// luminance, `alpha[k]` its coverage): per Laplacian coefficient the image whose luminance
    /// band has the largest region energy wins, the residual follows the deviation + entropy rule;
    /// with halo control (`p.halo` > 0) the levels coarser than `p.guide` are the mean of the
    /// images weighed by the guide's region energy to the power `p.halo`. Ties keep the earlier
    /// image; an image has no say where its coverage is below one half. Clamped to 0…1
    /// (photocraft `fuse_stack`).
    public static func fuseStack(width w: Int, height h: Int, channels ch: Int, images: [[Float]], luma: [[Float]], alpha: [[Float]],
                                 _ p: StackFusion = StackFusion(), on backend: Backend = .auto) throws -> [Float] {
        return try PhotoKit.run(backend, "Pyramid.fuseStack \(w)×\(h)", fits: PhotoKit.gpuFits(w, h, ch),
                                gpu: { try PyramidGPU.fuseStack(w, h, ch, images, luma, alpha, p) },
                                cpu: { fuseStackCPU(w, h, ch, images, luma, alpha, p) })
    }

    static func fuseStackCPU(_ w: Int, _ h: Int, _ ch: Int, _ images: [[Float]], _ luma: [[Float]], _ alpha: [[Float]], _ p: StackFusion) -> [Float] {
        let levels = fuseLevels(w, h, p)
        let bands = levels - 1
        let halo = haloSetting(bands, p)
        let nsel = halo.map { $0.g + 1 } ?? bands
        let win = binomial(max(p.energyRadius, 0))
        var acc: [Level] = []
        var best: [[Float]] = []
        var wsum: [[Float]] = []
        var tops: [Residual] = []
        for ((img, lm), al) in zip(zip(images, luma), alpha) {
            let lp = laplacian(width: w, height: h, channels: ch, img, levels: levels)
            let ll = laplacian(width: w, height: h, channels: 1, lm, levels: levels)
            let ga = gaussian(width: w, height: h, channels: 1, al, levels: levels)
            guard let top = lp.last, let tl = ll.last, let ta = ga.last else { continue }
            if lp.count != levels || ll.count != levels || ga.count != levels { continue }
            if halo == nil { tops.append(Residual(px: top, luma: tl.px, cover: ta.px)) }
            let energies = PhotoKit.parMap(nsel) { li in regionEnergy(ll[li], ga[li], win) }
            let wgt: Level? = halo.map { hl in
                Level(w: ll[hl.g].w, h: ll[hl.g].h, px: energies[hl.g].map { $0 < 0 ? 0 : haloWeight($0, hl.hard) })
            }
            if acc.isEmpty {
                acc = lp
                best = energies
                if let hl = halo, let wgt { foldHalo(&acc, &wsum, nil, hl.g, wgt, ch) }
                continue
            }
            for li in 0..<nsel {
                let lw = lp[li].w, lh = lp[li].h
                var take = [Bool](repeating: false, count: lw * lh)
                for i in 0..<min(energies[li].count, best[li].count) where energies[li][i] > best[li][i] {
                    best[li][i] = energies[li][i]
                    take[i] = true
                }
                let lvl = lp[li].px
                acc[li].px.withUnsafeMutableBufferPointer { a in
                    for i in 0..<(lw * lh) where take[i] {
                        for c in 0..<ch { a[i * ch + c] = lvl[i * ch + c] }
                    }
                }
            }
            if let hl = halo, let wgt { foldHalo(&acc, &wsum, lp, hl.g, wgt, ch) }
        }
        if acc.isEmpty { return [Float](repeating: 0, count: w * h * ch) }
        if let hl = halo {
            // The weighted means: Σ w·L / Σ w.
            if hl.g + 1 < levels {
                for li in (hl.g + 1)..<levels {
                    let s = wsum[li - hl.g - 1]
                    let n = acc[li].w * acc[li].h
                    acc[li].px.withUnsafeMutableBufferPointer { a in
                        for i in 0..<n {
                            let kv = s[i]
                            for c in 0..<ch { a[i * ch + c] = kv > 0 ? a[i * ch + c] / kv : 0 }
                        }
                    }
                }
            }
        } else {
            acc[acc.count - 1] = fuseResiduals(tops, ch)
        }
        return collapse(acc, channels: ch).map(PhotoKit.clamp01)
    }

    // MARK: - Weights

    /// One-hot winner maps: weight 1 for the image with the largest score at each pixel.
    static func winnerTakeAll(_ scores: [[Float]], _ n: Int) -> [[Float]] {
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: scores.count)
        let minF = -Float.greatestFiniteMagnitude
        for i in 0..<n {
            var best = (0, minF)
            for (k, s) in scores.enumerated() where s[i] > best.1 { best = (k, s[i]) }
            if best.1 > minF { out[best.0][i] = 1 }
        }
        return out
    }

    /// Focus-stack weights: per pixel, the image with the most local detail (smoothed |∇²L|) wins.
    /// `luma[k]` is image k's luminance, `alpha[k]` its coverage (photocraft `stack_weights`).
    public static func stackWeights(width w: Int, height h: Int, luma: [[Float]], alpha: [[Float]]) -> [[Float]] {
        let radius = min(max(min(w, h) / 64, 2), 12)
        let pairs = Array(zip(luma, alpha))
        let scores: [[Float]] = PhotoKit.parMap(pairs.count) { k in
            let (l, a) = pairs[k]
            var lap = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    @inline(__always) func p(_ xx: Int, _ yy: Int) -> Float { l[yy * w + xx] }
                    let xl = max(x - 1, 0), xr = min(x + 1, w - 1), yu = max(y - 1, 0), yd = min(y + 1, h - 1)
                    lap[y * w + x] = abs(p(xl, y) + p(xr, y) + p(x, yu) + p(x, yd) - 4 * p(x, y))
                }
            }
            return zip(PhotoKit.boxBlur(w, h, lap, radius), a).map { $1 > 0.5 ? $0 : -1 }
        }
        return winnerTakeAll(scores, w * h)
    }

    /// `stackWeights` on `backend` (the Metal path is bit-identical).
    public static func stackWeights(width w: Int, height h: Int, luma: [[Float]], alpha: [[Float]], on backend: Backend) throws -> [[Float]] {
        try PhotoKit.run(backend, "Pyramid.stackWeights", fits: PhotoKit.gpuFits(w, h, 1),
                         gpu: { try PyramidGPU.stackWeights(w, h, luma, alpha) },
                         cpu: { stackWeights(width: w, height: h, luma: luma, alpha: alpha) })
    }

    /// Panorama weights: each pixel goes to the image whose opaque area it lies deepest inside
    /// (3-4 chamfer distance to that image's transparent pixels), so seams run through overlaps
    /// (photocraft `panorama_weights`).
    public static func panoramaWeights(width w: Int, height h: Int, alpha: [[Float]]) -> [[Float]] {
        let scores: [[Float]] = PhotoKit.parMap(alpha.count) { k in
            let a = alpha[k]
            var d: [Float] = a.map { $0 > 0.5 ? 1.0e9 : 0 }
            @inline(__always) func at(_ d: [Float], _ x: Int, _ y: Int) -> Float {
                (x < 0 || y < 0 || x >= w || y >= h) ? 0 : d[y * w + x]
            }
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    var m = PhotoKit.fmin(d[i], at(d, x - 1, y) + 3)
                    m = PhotoKit.fmin(m, at(d, x, y - 1) + 3)
                    m = PhotoKit.fmin(m, at(d, x - 1, y - 1) + 4)
                    m = PhotoKit.fmin(m, at(d, x + 1, y - 1) + 4)
                    d[i] = m
                }
            }
            for y in stride(from: h - 1, through: 0, by: -1) {
                for x in stride(from: w - 1, through: 0, by: -1) {
                    let i = y * w + x
                    var m = PhotoKit.fmin(d[i], at(d, x + 1, y) + 3)
                    m = PhotoKit.fmin(m, at(d, x, y + 1) + 3)
                    m = PhotoKit.fmin(m, at(d, x + 1, y + 1) + 4)
                    m = PhotoKit.fmin(m, at(d, x - 1, y + 1) + 4)
                    d[i] = m
                }
            }
            return d.map { $0 <= 0 ? -1 : $0 }
        }
        return winnerTakeAll(scores, w * h)
    }
}
