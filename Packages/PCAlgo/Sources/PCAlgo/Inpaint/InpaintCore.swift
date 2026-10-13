// Port of photocraft-algo (crates/algo/src/inpaint.rs: Rng, Adapt, CompleteParams, Px, pyramid, valid sources, source index, targets, fit; photocraft-raster's Interrupt), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Hole filling for Content-Aware Fill and Spot Healing (photocraft `inpaint`): the shared pieces
// of the patch-based completion — the deterministic SplitMix64 generator, the pixel roles, the
// image pyramid, the valid-source map and its row/block index, the target map, and Image
// Melding's per-channel gain/bias fit. All buffers are interleaved `w × h × ch` normalised floats
// (any colour model, any depth) with `w × h` masks; every result is independent of the thread
// count.

import PCFoundation

/// Patch-based hole filling: completion, proximity match, texture synthesis, Content-Aware Fill
/// and the Remove Tool (photocraft `inpaint`, `content_aware`, `remove`, `nonlocal`).
public enum InpaintKit {
    /// Returned by an operation that stopped because its `Interrupt` was cancelled.
    public struct Cancelled: Error, Equatable, Sendable { public init() {} }

    /// Cancellation and progress for the long-running operations (photocraft-raster `Interrupt`).
    public struct Interrupt: Sendable {
        public var cancel: @Sendable () -> Bool
        public var progress: @Sendable (Float) -> Void

        public init(cancel: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (Float) -> Void = { _ in }) {
            self.cancel = cancel; self.progress = progress
        }

        /// Never cancelled; progress is ignored.
        public static let none = Interrupt(cancel: { false })

        public static func cancelOnly(_ cancel: @escaping @Sendable () -> Bool) -> Interrupt { Interrupt(cancel: cancel) }

        @inline(__always) var cancelled: Bool { cancel() }

        /// Reports progress (clamped to 0…1, NaN ignored).
        func report(_ f: Float) { if f.isFinite { progress(clampf(f, 0, 1)) } }

        @inline(__always) func check() throws { if cancel() { throw Cancelled() } }
    }

    /// SplitMix64: tiny deterministic RNG (photocraft `inpaint::Rng`).
    public struct Rng: Sendable {
        var state: UInt64
        public init(_ seed: UInt64) { state = seed ^ 0x9E37_79B9_7F4A_7C15 }

        @inline(__always)
        public mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Skip `n` numbers (the same state as after `n` calls of `next`).
        public mutating func skip(_ n: UInt64) { state = state &+ n &* 0x9E37_79B9_7F4A_7C15 }

        /// Uniform integer in `lo…hi`.
        @inline(__always)
        public mutating func range(_ lo: Int32, _ hi: Int32) -> Int32 {
            if hi <= lo { return lo }
            return lo &+ Int32(truncatingIfNeeded: next() % UInt64(Int64(hi) - Int64(lo) + 1))
        }
    }

    /// How far a copied patch may be adjusted to its target, per channel: `gain · source + bias`,
    /// the gain within `gain` and the bias within `±bias` (Image Melding's photometric transform).
    public struct Adapt: Codable, Sendable, Hashable {
        public var gain: SIMD2<Float>
        public var bias: Float
        public init(gain: SIMD2<Float>, bias: Float) { self.gain = gain; self.bias = bias }
        /// Copies are taken as they are.
        public static let none = Adapt(gain: SIMD2(1, 1), bias: 0)
        public var isNone: Bool { gain == SIMD2(1, 1) && bias == 0 }
    }

    /// Parameters for `complete` (photocraft `CompleteParams`).
    public struct CompleteParams: Codable, Sendable, Hashable {
        /// Patch radius (patches are `2r+1` square).
        public var patchRadius: Int = 3
        /// EM iterations at the coarsest level (finer levels use fewer, down to `minEmIters`).
        public var emIters: Int = 10
        public var minEmIters: Int = 3
        /// PatchMatch passes per EM iteration.
        public var pmIters: Int = 2
        /// Levels where the hole is wider than this only refine the scaled-up match field.
        public var refineExtent: Int = 192
        /// Colour adaptation of the copies.
        public var adapt: Adapt = .none
        public var seed: UInt64 = 1
        public init(patchRadius: Int = 3, emIters: Int = 10, minEmIters: Int = 3, pmIters: Int = 2, refineExtent: Int = 192,
                    adapt: Adapt = .none, seed: UInt64 = 1) {
            self.patchRadius = patchRadius; self.emIters = emIters; self.minEmIters = minEmIters; self.pmIters = pmIters
            self.refineExtent = refineExtent; self.adapt = adapt; self.seed = seed
        }
    }

    /// What a pixel is to `completeMasked` (photocraft `Px`).
    public enum Px: UInt8, Sendable, BitwiseCopyable {
        /// Not part of the image (a gap, or outside a transformed copy): ignored.
        case void
        /// Known, part of the context the fill must agree with, but not copied from.
        case known
        /// Known and may be copied from.
        case source
        /// To be filled.
        case hole
    }

    /// Below this many cells a pass runs on the calling thread.
    static let parMin = 64 * 64
    /// `parMin` for the passes that match or vote a patch per cell.
    static let parMinPatches = 16 * 16
    /// Largest level (in cells) whose source patches' moments `Solver.prepare` keeps.
    static let sourceMomentsMax = 1 << 20
    /// Most channels whose moments the colour adaptation fits.
    static let momCh = 8

    // MARK: Geometry

    /// The half-open box `[x0, x1) × [y0, y1)` of a level's grid.
    struct Bounds: Equatable, Sendable {
        var x0: Int, y0: Int, x1: Int, y1: Int
        /// Grown by `r` on every side, within a `w × h` grid.
        func grow(_ r: Int, _ w: Int, _ h: Int) -> Bounds {
            Bounds(x0: max(x0 - r, 0), y0: max(y0 - r, 0), x1: min(x1 + r, w), y1: min(y1 + r, h))
        }
        /// The same box on the next coarser level.
        var half: Bounds { Bounds(x0: x0 / 2, y0: y0 / 2, x1: (x1 + 1) / 2, y1: (y1 + 1) / 2) }
        var width: Int { max(x1 - x0, 0) }
        var height: Int { max(y1 - y0, 0) }
        var area: Int { width * height }
    }

    /// One pyramid level.
    struct Level {
        var w: Int, h: Int
        var img: [Float]
        var px: [Px]
    }

    /// Half-size level: a cell is a hole if any of its pixels is; else it averages its non-void
    /// pixels, and may be copied from only if all of them may.
    static func downsample(_ l: Level, _ ch: Int) -> Level {
        let w = (l.w + 1) / 2, h = (l.h + 1) / 2
        var img = [Float](repeating: 0, count: w * h * ch)
        var px = [Px](repeating: .void, count: w * h)
        let (lw, lh) = (l.w, l.h)
        l.img.withUnsafeBufferPointer { limg in
            l.px.withUnsafeBufferPointer { lpx in
                img.withUnsafeMutableBufferPointer { ib in
                    px.withUnsafeMutableBufferPointer { pb in
                        let (iS, pS) = (UnsafeSendable(ib), UnsafeSendable(pb))
                        let rowFn = { (y: Int) in
                            for x in 0..<w {
                                var n: Float = 0
                                let o = (y * w + x) * ch
                                var hole = false, allSource = true, any = false
                                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                                    let sx = x * 2 + dx, sy = y * 2 + dy
                                    if sx >= lw || sy >= lh { continue }
                                    let si = sy * lw + sx
                                    switch lpx[si] {
                                    case .hole: hole = true
                                    case .void: allSource = false
                                    case let k:
                                        any = true
                                        allSource = allSource && k == .source
                                        for c in 0..<ch { iS.value[o + c] += limg[si * ch + c] }
                                        n += 1
                                    }
                                }
                                if n > 0 { for c in 0..<ch { iS.value[o + c] /= n } }
                                pS.value[y * w + x] = hole ? .hole : (!any ? .void : (allSource ? .source : .known))
                            }
                        }
                        if w * h >= parMin { parallelChunks(h, minChunk: 4) { r in for y in r { rowFn(y) } } } else { for y in 0..<h { rowFn(y) } }
                    }
                }
            }
        }
        return Level(w: w, h: h, img: img, px: px)
    }

    /// Summed-area table of a boolean grid (`(w+1) × (h+1)`).
    static func integral(_ w: Int, _ h: Int, _ m: [Bool]) -> [UInt32] {
        var s = [UInt32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row: UInt32 = 0
            for x in 0..<w {
                row &+= m[y * w + x] ? 1 : 0
                s[(y + 1) * (w + 1) + x + 1] = s[y * (w + 1) + x + 1] &+ row
            }
        }
        return s
    }

    /// Count of set cells in the clipped window `[x0, x1) × [y0, y1)`.
    @inline(__always)
    static func windowCount(_ s: UnsafeBufferPointer<UInt32>, _ gw: Int, _ gh: Int, _ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> UInt32 {
        let ax0 = Int(max(x0, 0)), ay0 = Int(max(y0, 0))
        let ax1 = min(Int(max(x1, 0)), gw), ay1 = min(Int(max(y1, 0)), gh)
        if ax1 <= ax0 || ay1 <= ay0 { return 0 }
        let w1 = gw + 1
        return s[ay1 * w1 + ax1] &+ s[ay0 * w1 + ax0] &- s[ay0 * w1 + ax1] &- s[ay1 * w1 + ax0]
    }

    static func windowCount(_ s: [UInt32], _ gw: Int, _ gh: Int, _ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> UInt32 {
        s.withUnsafeBufferPointer { windowCount($0, gw, gh, x0, y0, x1, y1) }
    }

    /// Bounding box `(x0, y0, x1, y1)` of a mask.
    static func holeBBox(_ w: Int, _ h: Int, _ hole: [Bool]) -> (Int, Int, Int, Int)? {
        var b: (Int, Int, Int, Int)?
        for y in 0..<h {
            for x in 0..<w where hole[y * w + x] {
                if let c = b { b = (min(c.0, x), min(c.1, y), max(c.2, x + 1), max(c.3, y + 1)) } else { b = (x, y, x + 1, y + 1) }
            }
        }
        return b
    }

    /// Bounds of the hole pixels of a role grid.
    static func holeBounds(_ w: Int, _ h: Int, _ px: [Px]) -> Bounds? {
        var b: Bounds?
        px.withUnsafeBufferPointer { p in
            for y in 0..<h {
                var x0 = -1, x1 = -1
                for x in 0..<w where p[y * w + x] == .hole { if x0 < 0 { x0 = x }; x1 = x + 1 }
                if x0 < 0 { continue }
                if let c = b { b = Bounds(x0: min(c.x0, x0), y0: c.y0, x1: max(c.x1, x1), y1: y + 1) } else { b = Bounds(x0: x0, y0: y, x1: x1, y1: y + 1) }
            }
        }
        return b
    }

    /// Valid source centres: the whole `2r+1` patch inside the grid and copyable (photocraft
    /// `valid_sources`; computed from a summed-area table of the copyable pixels — the same set).
    static func validSources(_ w: Int, _ h: Int, _ r: Int, _ px: [Px], _ ctl: Interrupt) throws -> [Bool] {
        let side = 2 * r + 1
        var valid = [Bool](repeating: false, count: w * h)
        if w < side || h < side { return valid }
        try ctl.check()
        let s = integral(w, h, px.map { $0 == .source })
        let full = UInt32(side * side)
        s.withUnsafeBufferPointer { sb in
            valid.withUnsafeMutableBufferPointer { vb in
                let vs = UnsafeSendable(vb)
                parallelChunks(h, minChunk: 16) { rows in
                    for y in rows where y >= r && y + r < h {
                        for x in r..<(w - r) {
                            vs.value[y * w + x] = windowCount(sb, w, h, Int32(x - r), Int32(y - r), Int32(x + r + 1), Int32(y + r + 1)) == full
                        }
                    }
                }
            }
        }
        try ctl.check()
        return valid
    }

    /// Columns per block of `Sources`' index.
    static let sourceBlock = 64

    /// The valid source centres in row-major order, indexed by counts per row and per block of
    /// `sourceBlock` columns (so the k-th is found without listing them all).
    struct Sources {
        /// Valid centres before each row (`h + 1` entries).
        var rowStart: [Int]
        /// Per row, the valid centres in it before each block.
        var blockStart: [UInt32]
        var blocks: Int

        init(_ valid: [Bool], _ w: Int) {
            let h = w > 0 ? valid.count / w : 0
            blocks = (w + sourceBlock - 1) / sourceBlock
            var bs = [UInt32](repeating: 0, count: h * blocks)
            var rs = [Int](repeating: 0, count: h + 1)
            let nb = blocks
            valid.withUnsafeBufferPointer { v in
                bs.withUnsafeMutableBufferPointer { b in
                    rs.withUnsafeMutableBufferPointer { rsb in
                        let (bS, rS) = (UnsafeSendable(b), UnsafeSendable(rsb))
                        parallelChunks(h, minChunk: 16) { rows in
                            for y in rows {
                                var n: UInt32 = 0
                                for bi in 0..<nb {
                                    bS.value[y * nb + bi] = n
                                    for x in (bi * sourceBlock)..<min((bi + 1) * sourceBlock, w) where v[y * w + x] { n += 1 }
                                }
                                rS.value[y + 1] = Int(n)
                            }
                        }
                    }
                }
            }
            for y in 0..<h { rs[y + 1] += rs[y] }
            rowStart = rs
            blockStart = bs
        }

        var count: Int { rowStart.last ?? 0 }

        /// The k-th valid centre in row-major order (`k < count`).
        func nth(_ k: Int, _ valid: [Bool], _ w: Int) -> (Int32, Int32) {
            // partition_point(|s| s <= k) - 1
            var lo = 0, hi = rowStart.count
            while lo < hi { let m = (lo + hi) / 2; if rowStart[m] <= k { lo = m + 1 } else { hi = m } }
            let y = max(lo - 1, 0)
            let left0 = max(k - (y < rowStart.count ? rowStart[y] : 0), 0)
            let rowBase = y * blocks
            var blo = 0, bhi = blocks
            while blo < bhi { let m = (blo + bhi) / 2; if Int(blockStart[rowBase + m]) <= left0 { blo = m + 1 } else { bhi = m } }
            let b = max(blo - 1, 0)
            var left = max(left0 - (blocks > 0 ? Int(blockStart[rowBase + b]) : 0), 0)
            let x0 = b * sourceBlock
            if x0 < w {
                for x in x0..<w where valid[y * w + x] {
                    if left == 0 { return (Int32(x), Int32(y)) }
                    left -= 1
                }
            }
            return (0, 0)
        }

        /// All of them, in row-major order.
        func all(_ valid: [Bool], _ w: Int) -> [(Int32, Int32)] {
            var out: [(Int32, Int32)] = []
            out.reserveCapacity(count)
            for (i, v) in valid.enumerated() where v { out.append((Int32(i % w), Int32(i / w))) }
            return out
        }
    }

    /// Per cell of `tb` (the hole's bounds `hb` grown by the patch radius): is it a target centre
    /// (its patch overlaps the hole)?
    static func targetsAround(_ w: Int, _ r: Int, _ px: [Px], _ hb: Bounds, _ tb: Bounds) -> [Bool] {
        let (bw, bh) = (hb.width, hb.height)
        var s = [UInt32](repeating: 0, count: (bw + 1) * (bh + 1))
        for y in 0..<bh {
            var row: UInt32 = 0
            for x in 0..<bw {
                row += px[(hb.y0 + y) * w + hb.x0 + x] == .hole ? 1 : 0
                s[(y + 1) * (bw + 1) + x + 1] = s[y * (bw + 1) + x + 1] + row
            }
        }
        var targets = [Bool](repeating: false, count: tb.area)
        let ri = Int32(r)
        let (ox, oy) = (Int32(hb.x0), Int32(hb.y0))
        s.withUnsafeBufferPointer { sb in
            for y in tb.y0..<tb.y1 {
                for x in tb.x0..<tb.x1 {
                    let k = (y - tb.y0) * tb.width + (x - tb.x0)
                    let (xi, yi) = (Int32(x), Int32(y))
                    targets[k] = windowCount(sb, bw, bh, xi - ri - ox, yi - ri - oy, xi + ri + 1 - ox, yi + ri + 1 - oy) > 0
                }
            }
        }
        return targets
    }

    /// A finished coarser level: its size, pixels and match field (the source centre per cell of
    /// its target box, `Int32.min` where there is none; empty when it had nothing to copy).
    struct Coarser {
        var w: Int, h: Int
        var img: [Float]
        var field: [(Int32, Int32)]
        var tbox: Bounds

        func fieldAt(_ x: Int, _ y: Int) -> (Int32, Int32) {
            let t = tbox
            if x < t.x0 || x >= t.x1 || y < t.y0 || y >= t.y1 { return (.min, .min) }
            let k = (y - t.y0) * t.width + (x - t.x0)
            return k < field.count ? field[k] : (.min, .min)
        }
    }

    /// Gain and bias of one channel for target moments `(Σt, Σt²)` and source moments `(Σs, Σs²)`
    /// over `n` samples, within the limits (photocraft `fit`).
    @inline(__always)
    static func fit(_ a: Adapt, _ n: Float, _ st: Float, _ stt: Float, _ ss: Float, _ sss: Float) -> (Float, Float) {
        let mt = st / n, ms = ss / n
        let vt = Float.maximum(stt / n - mt * mt, 0)
        let vs = Float.maximum(sss / n - ms * ms, 0)
        let g0: Float = vs > 1e-10 ? (vt / vs).squareRoot() : 1
        let g = clampf(g0, a.gain.x, a.gain.y)
        let b = clampf(mt - g * ms, -a.bias, a.bias)
        return (g, b)
    }

    /// The adapted distance from the moments `[Σt, Σt², Σs, Σs², Σts]` of each channel over `n`
    /// samples: what is left of the target after the source is fitted to it, per sample.
    @inline(__always)
    static func adaptedCost(_ a: Adapt, _ nf: Float, _ m: UnsafeBufferPointer<SIMD8<Float>>, _ c8: Int) -> Float {
        var sum: Float = 0
        for c in 0..<c8 {
            let mc = m[c]
            let (g, b) = fit(a, nf, mc[0], mc[1], mc[2], mc[3])
            // Σ (t − g s − b)², expanded.
            sum += mc[1] + g * g * mc[3] + nf * b * b - 2 * g * mc[4] - 2 * b * mc[0] + 2 * g * b * mc[2]
        }
        return Float.maximum(sum, 0) / (nf * Float(c8))
    }

    /// `Σv, Σv²` per channel (the first `c8`) of the `side × side` patch with top-left `(x0, y0)`,
    /// summed row by row, pixel by pixel.
    @inline(__always)
    static func patchMoments(_ img: UnsafePointer<Float>, _ w: Int, _ ch: Int, _ c8: Int, _ side: Int, _ x0: Int, _ y0: Int,
                             _ out: UnsafeMutablePointer<SIMD2<Float>>) {
        for c in 0..<c8 { out[c] = .zero }
        for y in y0..<(y0 + side) {
            var p = img + (y * w + x0) * ch
            for _ in 0..<side {
                for c in 0..<c8 {
                    let a = p[c]
                    out[c].x += a
                    out[c].y += a * a
                }
                p += ch
            }
        }
    }

    /// The least sum `e ≥ 0` with `e / n > v` (`strict`) or `e / n ≥ v` in float arithmetic;
    /// infinity for an infinite `v` (photocraft `least_sum`).
    static func leastSum(_ v: Float, _ n: Float, _ strict: Bool) -> Float {
        @inline(__always) func holds(_ e: Float) -> Bool { strict ? e / n > v : e / n >= v }
        if !v.isFinite || !n.isFinite || n <= 0 { return .infinity }
        var e = Float.maximum(v * n, 0)
        while e > 0 && holds(e.nextDown) { e = e.nextDown }
        while !holds(e) && e < .infinity { e = e.nextUp }
        return e
    }
}
