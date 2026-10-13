// Port of photocraft-algo (crates/algo/src/content_aware.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edit › Content-Aware Fill: patch-based completion (`InpaintKit.completeMasked`) with Photoshop's
// sampling area, colour adaptation and geometric adaptation, as photocraft measured Photoshop 25.4:
// - the fill copies only from a square of side 4·√(max(w, 50)·max(h, 50)) centred on the
//   selection's bounds, slid inside the canvas (`samplingWindow`);
// - Auto sampling keeps, within it, what looks like the selection's surroundings (`autoSampling`:
//   per-cell mean colour and local contrast, a few clusters of the ring around the hole, one
//   contrast-sensitive min cut);
// - colour adaptation None / Default / High / Very High lets copies take a gain and bias (Image
//   Melding, Darabi et al. 2012);
// - rotation / scale / mirror adaptation extends the source with transformed copies of itself, laid
//   out beside it with gaps that are no image (after Generalised PatchMatch, Barnes et al. 2010).

import Foundation
import PCFoundation

extension InpaintKit {
    /// Options for `fill` (photocraft `FillOptions`).
    public struct FillOptions: Codable, Sendable, Hashable {
        /// Colour adaptation of the copies (`colorLevel`).
        public var colorAdaptation: Adapt
        /// Extra source rotations in degrees (`rotationLevel`).
        public var rotations: [Float]
        /// Add downscaled and upscaled source copies.
        public var scale: Bool
        /// Add a horizontally mirrored source copy.
        public var mirror: Bool
        public var seed: UInt64

        public init(colorAdaptation: Adapt = InpaintKit.colorLevel("default"), rotations: [Float] = [], scale: Bool = false,
                    mirror: Bool = false, seed: UInt64 = 1) {
            self.colorAdaptation = colorAdaptation; self.rotations = rotations; self.scale = scale; self.mirror = mirror; self.seed = seed
        }
    }

    /// Rotation set for Photoshop's adaptation levels: none, low, medium, high, full.
    public static func rotationLevel(_ level: String) -> [Float] {
        switch level {
        case "low": [-10, 10]
        case "medium": [-20, 20]
        case "high": [-35, 35]
        case "full": [90, 180, 270]
        default: []
        }
    }

    /// Colour adaptation for Photoshop's levels: none, default, high, veryHigh.
    public static func colorLevel(_ level: String) -> Adapt {
        switch level {
        case "none": .none
        case "high": Adapt(gain: SIMD2(0.8, 1.25), bias: 0.08)
        case "veryHigh": Adapt(gain: SIMD2(0.67, 1.5), bias: 0.14)
        default: Adapt(gain: SIMD2(0.9, 1.1), bias: 0.04)
        }
    }

    /// Photoshop's sampling window for a selection with bounding box `hole`: the square of side
    /// `4·√(max(w, 50)·max(h, 50))` centred on it, slid inside `canvas` (and clipped to it only
    /// where the canvas is smaller). A selection longer than the square keeps its whole length.
    public static func samplingWindow(hole: PixelRect, canvas: PixelRect) -> PixelRect {
        if hole.isEmpty || canvas.isEmpty { return .empty }
        let w = Double(max(hole.width, 50)), h = Double(max(hole.height, 50))
        let side = Int64(min((4 * (w * h).squareRoot()).rounded(), Double(Int32.max)))
        // Twice the centre, so that odd sizes stay exact.
        func span(_ c2: Int64, _ extent: Int, _ lo32: Int32, _ hi32: Int32) -> (Int32, Int32) {
            let lo = Int64(lo32), hi = Int64(hi32)
            let s = max(side, Int64(extent))
            if s >= hi - lo { return (lo32, hi32) }
            let a = min(max((c2 - s) / 2, lo), hi - s)
            return (Int32(a), Int32(a + s))
        }
        let (x0, x1) = span(Int64(hole.x0) + Int64(hole.x1), hole.width, canvas.x0, canvas.x1)
        let (y0, y1) = span(Int64(hole.y0) + Int64(hole.y1), hole.height, canvas.y0, canvas.y1)
        return PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// One source variant: pixels and which of them are usable.
    struct Variant {
        var w: Int, h: Int
        var img: [Float]
        var ok: [Bool]
    }

    /// Bilinear sample of the source at (x, y); false when any tap is unusable.
    @inline(__always)
    static func sample(_ w: Int, _ h: Int, _ ch: Int, _ img: UnsafePointer<Float>, _ ok: UnsafePointer<Bool>, _ x: Float, _ y: Float,
                       _ out: UnsafeMutablePointer<Float>) -> Bool {
        if x < 0 || y < 0 || x > Float(w - 1) || y > Float(h - 1) { return false }
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let tx = x - Float(x0), ty = y - Float(y0)
        for (xx, yy) in [(x0, y0), (x1, y0), (x0, y1), (x1, y1)] where !ok[yy * w + xx] { return false }
        for c in 0..<ch {
            @inline(__always) func p(_ xx: Int, _ yy: Int) -> Float { img[(yy * w + xx) * ch + c] }
            let top = p(x0, y0) + (p(x1, y0) - p(x0, y0)) * tx
            let bot = p(x0, y1) + (p(x1, y1) - p(x0, y1)) * tx
            out[c] = top + (bot - top) * ty
        }
        return true
    }

    /// Transformed copy of the source: rotation (degrees) and scale about the centre, optional
    /// mirror (photocraft `variant`).
    static func variant(_ w: Int, _ h: Int, _ ch: Int, _ img: [Float], _ ok: [Bool], _ deg: Float, _ scale: Float, _ mirror: Bool,
                        _ ctl: Interrupt) throws -> Variant {
        let a = -PCAMath.radians(deg)
        let (s, c) = (sinf(a), cosf(a))
        // Output size: the rotated, scaled bounding box.
        let fw = Float(w) * scale, fh = Float(h) * scale
        let ow = max(Int((fw * abs(c) + fh * abs(s)).rounded()), 1)
        let oh = max(Int((fw * abs(s) + fh * abs(c)).rounded()), 1)
        let icx = (Float(w) - 1) / 2, icy = (Float(h) - 1) / 2
        let ocx = (Float(ow) - 1) / 2, ocy = (Float(oh) - 1) / 2
        var out = Variant(w: ow, h: oh, img: [Float](repeating: 0, count: ow * oh * ch), ok: [Bool](repeating: false, count: ow * oh))
        img.withUnsafeBufferPointer { ib in
            ok.withUnsafeBufferPointer { kb in
                out.img.withUnsafeMutableBufferPointer { oib in
                    out.ok.withUnsafeMutableBufferPointer { okb in
                        let (iS, kS, oS, okS) = (UnsafeSendable(ib.baseAddress!), UnsafeSendable(kb.baseAddress!), UnsafeSendable(oib), UnsafeSendable(okb))
                        parallelChunks(oh, minChunk: 4) { rows in
                            var px = [Float](repeating: 0, count: max(ch, 1))
                            for y in rows {
                                if ctl.cancelled { return }
                                for x in 0..<ow {
                                    let dx = (Float(x) - ocx) / scale, dy = (Float(y) - ocy) / scale
                                    var sx = icx + dx * c - dy * s
                                    let sy = icy + dx * s + dy * c
                                    if mirror { sx = (Float(w) - 1) - sx }
                                    let got = px.withUnsafeMutableBufferPointer { sample(w, h, ch, iS.value, kS.value, sx, sy, $0.baseAddress!) }
                                    if got {
                                        okS.value[y * ow + x] = true
                                        for k in 0..<ch { oS.value[(y * ow + x) * ch + k] = px[k] }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        try ctl.check()
        return out
    }

    /// Fill `hole` in `img`, copying only from pixels where `source` is true (and not in the hole).
    /// Returns the full buffer (unchanged outside the hole); the membrane fill when nothing can be
    /// sampled (photocraft `content_aware::fill`). `on:` as for `complete`.
    public static func fill(width w: Int, height h: Int, channels ch: Int, image img: [Float], hole: [Bool], source: [Bool],
                            options: FillOptions = FillOptions(), on backend: Backend = .cpu) -> [Float] {
        (try? fillWith(width: w, height: h, channels: ch, image: img, hole: hole, source: source, options: options, interrupt: .none, on: backend)) ?? img
    }

    /// `fill` that can be cancelled and reports progress (photocraft `fill_with` / `fill_owned`).
    public static func fillWith(width w: Int, height h: Int, channels ch: Int, image img: [Float], hole: [Bool], source: [Bool],
                                options opts: FillOptions, interrupt ctl: Interrupt, on backend: Backend = .cpu) throws -> [Float] {
        precondition(img.count == w * h * ch && hole.count == w * h && source.count == w * h)
        if !hole.contains(true) { return img }
        let params = CompleteParams(adapt: opts.colorAdaptation, seed: opts.seed)
        let gap = 2 * params.patchRadius + 2
        let ok = (0..<(w * h)).map { !hole[$0] && source[$0] }
        // Variants: the identity (which holds the hole) first, then the adaptations.
        var extra: [Variant] = []
        if opts.mirror { extra.append(try variant(w, h, ch, img, ok, 0, 1, true, ctl)) }
        for deg in opts.rotations { extra.append(try variant(w, h, ch, img, ok, deg, 1, false, ctl)) }
        if opts.scale {
            extra.append(try variant(w, h, ch, img, ok, 0, 0.8, false, ctl))
            extra.append(try variant(w, h, ch, img, ok, 0, 1.25, false, ctl))
        }
        func role(_ s: Int) -> Px { hole[s] ? .hole : (ok[s] ? .source : .known) }
        // The completion is nearly all the work.
        let inner = Interrupt(cancel: ctl.cancel, progress: { [ctl] f in ctl.report(f * 0.99) })
        var out: [Float]
        if extra.isEmpty {
            // Without variants the image itself is completed (it changes only in the hole).
            if let f = try completeMasked(width: w, height: h, channels: ch, image: img, roles: (0..<(w * h)).map(role), params: params,
                                          interrupt: inner, on: backend) {
                out = f
            } else {
                out = Poisson.membraneFill(width: w, height: h, channels: ch, image: img, hole: hole)
                try ctl.check()
            }
        } else {
            // Mosaic: identity at the left, variants in a column to its right, gaps that are no image.
            let colW = extra.map(\.w).max() ?? 0
            let colH = extra.reduce(0) { $0 + $1.h + gap }
            let mw = w + gap + colW, mh = max(h, colH)
            var mimg = [Float](repeating: 0, count: mw * mh * ch)
            var roles = [Px](repeating: .void, count: mw * mh)
            for y in 0..<h {
                for x in 0..<w {
                    let s = y * w + x, d = y * mw + x
                    for c in 0..<ch { mimg[d * ch + c] = img[s * ch + c] }
                    roles[d] = role(s)
                }
            }
            var oy = 0
            for v in extra {
                try ctl.check()
                for y in 0..<v.h {
                    for x in 0..<v.w {
                        let s = y * v.w + x, d = (oy + y) * mw + w + gap + x
                        for c in 0..<ch { mimg[d * ch + c] = v.img[s * ch + c] }
                        if v.ok[s] { roles[d] = .source }
                    }
                }
                oy += v.h + gap
            }
            try ctl.check()
            if let f = try completeMasked(width: mw, height: mh, channels: ch, image: mimg, roles: roles, params: params, interrupt: inner, on: backend) {
                out = img
                for y in 0..<h {
                    for x in 0..<w where hole[y * w + x] {
                        let s = (y * mw + x) * ch, d = (y * w + x) * ch
                        for c in 0..<ch { out[d + c] = f[s + c] }
                    }
                }
            } else {
                out = Poisson.membraneFill(width: w, height: h, channels: ch, image: img, hole: hole)
                try ctl.check()
            }
        }
        try ctl.check()
        ctl.report(1)
        return out
    }

    // MARK: Auto sampling

    /// Box mean of radius `r` over a `w × h` plane (edge-clamped), by summed areas in f64.
    static func caBoxMean(_ w: Int, _ h: Int, _ v: [Float], _ r: Int) -> [Float] {
        let w1 = w + 1
        var s = [Double](repeating: 0, count: w1 * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                row += Double(v[y * w + x])
                s[(y + 1) * w1 + x + 1] = s[y * w1 + x + 1] + row
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(y - r, 0), y1 = min(y + r + 1, h)
            for x in 0..<w {
                let x0 = max(x - r, 0), x1 = min(x + r + 1, w)
                let sum = s[y1 * w1 + x1] + s[y0 * w1 + x0] - s[y0 * w1 + x1] - s[y1 * w1 + x0]
                out[y * w + x] = Float(sum / Double((x1 - x0) * (y1 - y0)))
            }
        }
        return out
    }

    /// Largest side `autoSampling` works at.
    static let autoSide = 384

    /// Content-Aware Fill's Auto sampling area within a window (the whole `w × h` buffer): the
    /// pixels that look like the hole's surroundings. Never the hole; everything outside it when
    /// the area would be too small to copy from (photocraft `auto_sampling`).
    public static func autoSampling(width w: Int, height h: Int, channels ch: Int, image img: [Float], hole: [Bool]) -> [Bool] {
        (try? autoSamplingWith(width: w, height: h, channels: ch, image: img, hole: hole, interrupt: .none)) ?? hole.map { !$0 }
    }

    /// `autoSampling` that can be cancelled.
    public static func autoSamplingWith(width w: Int, height h: Int, channels ch: Int, image img: [Float], hole: [Bool],
                                        interrupt ctl: Interrupt) throws -> [Bool] {
        precondition(img.count == w * h * ch && hole.count == w * h)
        let everything = { hole.map { !$0 } }
        if w == 0 || h == 0 || ch == 0 || !hole.contains(true) { return everything() }
        // Work at a reduced scale for big windows.
        let k = max((max(w, h) + autoSide - 1) / autoSide, 1)
        let sw = (w + k - 1) / k, sh = (h + k - 1) / k
        let nc = min(ch, 3)
        // Per cell: the sums of its colour planes, its pixel count and whether it holds the hole.
        let st = nc + 2
        var sums = [Float](repeating: 0, count: sw * sh * st)
        sums.withUnsafeMutableBufferPointer { sb in
            let sS = UnsafeSendable(sb)
            parallelChunks(sh, minChunk: 1) { rows in
                for sy in rows {
                    if ctl.cancelled { return }
                    for y in (sy * k)..<min((sy + 1) * k, h) {
                        for x in 0..<w {
                            let cell = (sy * sw + x / k) * st
                            let p = y * w + x
                            if hole[p] { sS.value[cell + nc + 1] = 1 }
                            for c in 0..<nc { sS.value[cell + c] += img[p * ch + c] }
                            sS.value[cell + nc] += 1
                        }
                    }
                }
            }
        }
        try ctl.check()
        let planes: [[Float]] = (0..<nc).map { c in (0..<(sw * sh)).map { i in sums[i * st + c] / Float.maximum(sums[i * st + nc], 1) } }
        let shole = (0..<(sw * sh)).map { sums[$0 * st + nc + 1] > 0 }
        // Features: local means and local contrast (of the average of the colour planes).
        let r = 3
        let means = planes.map { caBoxMean(sw, sh, $0, r) }
        let luma: [Float] = (0..<(sw * sh)).map { i in
            var s: Float = -0.0
            for p in planes { s += p[i] }
            return s / Float(nc)
        }
        let lm = caBoxMean(sw, sh, luma, r), lm2 = caBoxMean(sw, sh, luma.map { $0 * $0 }, r)
        let contrast = zip(lm, lm2).map { Float.maximum($1 - $0 * $0, 0).squareRoot() }
        let nf = nc + 1
        func feat(_ i: Int, _ out: inout [Float]) {
            for c in 0..<nc { out[c] = means[c][i] }
            out[nc] = 2 * contrast[i]
        }
        // The ring: outside the hole, within a few pixels of it.
        let dist = edt(shole, sw, sh)
        let ringW = 6 / Float(k) + 1
        let ring = (0..<(sw * sh)).filter { !shole[$0] && dist[$0] <= ringW }
        if ring.isEmpty { return everything() }
        try ctl.check()
        // A few cluster centres of the ring's features (k-means, deterministic start).
        let kc = min(6, ring.count)
        var f = [Float](repeating: 0, count: nf)
        var centres: [[Float]] = (0..<kc).map { j in feat(ring[j * ring.count / kc], &f); return f }
        func d2(_ a: [Float], _ b: [Float]) -> Float {
            var s: Float = -0.0
            for i in 0..<a.count { let d = a[i] - b[i]; s += d * d }
            return s
        }
        for _ in 0..<8 {
            var acc = [[Float]](repeating: [Float](repeating: 0, count: nf), count: kc)
            var n = [Int](repeating: 0, count: kc)
            for i in ring {
                feat(i, &f)
                // `min_by(total_cmp)`: the first of equal minima.
                var j = 0
                var bd = d2(f, centres[0])
                for jj in 1..<kc {
                    let d = d2(f, centres[jj])
                    if d.isTotallyOrdered(belowOrEqualTo: bd) && !bd.isTotallyOrdered(belowOrEqualTo: d) { j = jj; bd = d }
                }
                for t in 0..<nf { acc[j][t] += f[t] }
                n[j] += 1
            }
            for j in 0..<kc where n[j] > 0 { centres[j] = acc[j].map { $0 / Float(n[j]) } }
        }
        func nearest(_ i: Int, _ f: inout [Float]) -> Float {
            feat(i, &f)
            var m = Float.infinity
            for c in centres { m = Float.minimum(m, d2(f, c)) }
            return m.squareRoot()
        }
        // How much the ring itself varies around its clusters sets the scale of "similar".
        let spread = ring.map { nearest($0, &f) }
        let q = min(spread.count * 9 / 10, spread.count - 1)
        let s90 = ToneKit.totalSorted(spread)[q]
        let tau = Float.maximum(s90 * 1.6, 0.03)
        var costFG = [Float](repeating: 0, count: sw * sh), costBG = [Float](repeating: 0, count: sw * sh)
        var fixed = [UInt8](repeating: free, count: sw * sh)
        for i in 0..<(sw * sh) {
            if shole[i] || dist[i] <= 1.5 { fixed[i] = hardFG; continue }
            let d = nearest(i, &f) / tau
            costFG[i] = d * d
            costBG[i] = 1
        }
        let rgb: [SIMD3<Float>] = (0..<(sw * sh)).map { i in SIMD3(means[0][i], means[min(1, nc - 1)][i], means[min(2, nc - 1)][i]) }
        // Contrast-sensitive smoothness, fitted by photocraft to Photoshop's Auto overlays.
        try ctl.check()
        guard let area = gridCut(sw, sh, rgb, costFG, costBG, fixed, { d2 in 8 * expf(-d2 / (2 * 0.05 * 0.05)) + 0.05 }, { ctl.cancelled }) else {
            throw Cancelled()
        }
        var out = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { out[y * w + x] = !hole[y * w + x] && area[(y / k) * sw + x / k] } }
        // Too little to copy from (fewer source pixels than twice the hole): sample everything.
        let nHole = hole.reduce(0) { $0 + ($1 ? 1 : 0) }
        if out.reduce(0, { $0 + ($1 ? 1 : 0) }) < 2 * max(nHole, 64) { return everything() }
        return out
    }

    // MARK: Patch / Content-Aware Move colour

    /// The Patch Tool's and the Content-Aware Move Tool's Color option (0–10) as the colour
    /// adaptation of the copied content (photocraft `color_amount`).
    public static func colorAmount(_ color: UInt8) -> Adapt {
        if color == 0 { return .none }
        let c = Float(min(color, 10))
        return Adapt(gain: SIMD2(1 - 0.033 * c, 1 + 0.05 * c), bias: 0.04 * c)
    }

    /// Gain and bias per channel taking the samples `from` to the level and contrast of the samples
    /// `to` (both interleaved, `ch` per sample), within `a` (photocraft `level_transform`).
    public static func levelTransform(channels ch: Int, from: [Float], to: [Float], adapt a: Adapt) -> [SIMD2<Float>] {
        func moments(_ v: [Float], _ c: Int) -> (Double, Double, Double) {
            var s = 0.0, s2 = 0.0, n = 0.0
            let step = max(ch, 1)
            var i = 0
            while i + step <= v.count {
                let x = Double(v[i + c])
                s += x; s2 += x * x; n += 1
                i += step
            }
            return (s, s2, n)
        }
        return (0..<ch).map { c in
            let (fs, fs2, fnn) = moments(from, c)
            let (ts, ts2, tn) = moments(to, c)
            if a.isNone || fnn == 0 || tn == 0 { return SIMD2(1, 0) }
            // Both sets scaled to the same count for the fit.
            let k = fnn / tn
            let (g, b) = fit(a, Float(fnn), Float(ts * k), Float(ts2 * k), Float(fs), Float(fs2))
            return SIMD2(g, b)
        }
    }
}
