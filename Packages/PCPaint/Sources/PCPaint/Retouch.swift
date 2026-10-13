// Port of photocraft-paint (crates/paint/src/retouch.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Generic dab-driven stroke machinery for the retouching tools (Clone Stamp, Healing Brush, Spot
// Healing, Dodge/Burn/Sponge, Blur/Sharpen, Smudge, History Brush). Two stroke shapes cover every
// retouching tool:
//
// * Accumulate, then composite (`strokeCoverage` + `applyCoverage`): the stroke's dabs build up
//   one coverage map (flow builds up, capped at 1), and a *paint image* computed once from the
//   pre-stroke state (a cloned source, a healed patch, an earlier history state…) is composited
//   through it at the stroke's opacity. Pixels painted earlier in the same stroke are never
//   re-sampled.
// * Sequential dabs (`applyDabStroke`): each dab edits a working copy in place (so dab n sees the
//   result of dab n − 1, as Dodge, Blur or Smudge need), and the finished working copy is mixed
//   back at the stroke's opacity.
//
// All pixel data here is the surface's native channels as normalised Float (any depth, any colour
// model); colour-space-specific work happens in the callbacks.

import PCFoundation

/// A rectangle of native-channel pixels (`rect.width × rect.height × ch` floats, row-major).
public struct Region: Equatable, Sendable {
    public var rect: PixelRect
    public var ch: Int
    public var data: [Float]

    /// A zeroed region.
    public init(rect: PixelRect, ch: Int) {
        self.rect = rect; self.ch = ch
        data = [Float](repeating: 0, count: rect.area * ch)
    }

    public init(rect: PixelRect, ch: Int, data: [Float]) {
        self.rect = rect; self.ch = ch; self.data = data
    }

    /// Read `rect` from a surface.
    public static func read(_ s: Surface, _ rect: PixelRect) -> Region {
        Region(rect: rect, ch: s.channels, data: rect.isEmpty ? [] : s.readRegion(rect))
    }

    public var width: Int { rect.width }
    public var height: Int { rect.height }

    /// Pixel index of document coordinate (x, y) (must lie inside `rect`).
    @inline(__always) public func index(_ x: Int32, _ y: Int32) -> Int { Int(y - rect.y0) * width + Int(x - rect.x0) }

    public func px(_ x: Int32, _ y: Int32) -> ArraySlice<Float> {
        let i = index(x, y) * ch
        return data[i..<i + ch]
    }

    /// Mutable access to one pixel's channels.
    @inline(__always) public mutating func withPixel<R>(_ x: Int32, _ y: Int32, _ body: (UnsafeMutableBufferPointer<Float>) -> R) -> R {
        let i = index(x, y) * ch
        let n = ch
        return data.withUnsafeMutableBufferPointer { body(UnsafeMutableBufferPointer(rebasing: $0[i..<i + n])) }
    }

    /// Copy of the sub-rectangle `r` (clipped to this region).
    public func crop(_ r0: PixelRect) -> Region {
        let r = r0.intersect(rect)
        var out = Region(rect: r, ch: ch)
        let w = r.width, n = ch
        if r.isEmpty { return out }
        for y in r.y0..<r.y1 {
            let s = index(r.x0, y) * n
            let d = Int(y - r.y0) * w * n
            for i in 0..<(w * n) { out.data[d + i] = data[s + i] }
        }
        return out
    }

    /// Write this region into a surface.
    public func write(_ s: inout Surface) {
        var d = data
        s.writeRegionSafe(rect, &d)
    }
}

/// One dab's footprint: coverage (hardness falloff × dab alpha) over its bounding rectangle.
public struct Footprint: Equatable, Sendable {
    public var dab: Dab
    /// Position of the dab in the stroke (0 = first).
    public var index: Int
    public var rect: PixelRect
    /// `rect.width × rect.height` coverage values in 0…1 (already multiplied by flow/pressure).
    public var cov: [Float]

    @inline(__always) public func at(_ x: Int32, _ y: Int32) -> Float {
        cov[Int(y - rect.y0) * rect.width + Int(x - rect.x0)]
    }
}

public enum Retouch {
    /// Bounding rectangle of a dab (1 px of anti-aliasing slack included).
    public static func dabRect(_ d: Dab) -> PixelRect { rectAround(d, d.radius) }

    /// Rasterise one dab's coverage (round tip).
    public static func footprint(_ d: Dab, index: Int, hardness: Float) -> Footprint {
        let rect = dabRect(d)
        let cx = Float(d.center.x), cy = Float(d.center.y)
        var cov: [Float] = []
        cov.reserveCapacity(rect.area)
        if !rect.isEmpty {
            for y in rect.y0..<rect.y1 {
                for x in rect.x0..<rect.x1 {
                    let ex = Float(x) + 0.5 - cx, ey = Float(y) + 0.5 - cy
                    let dist = (ex * ex + ey * ey).squareRoot()
                    cov.append(dabCoverage(dist, d.radius, hardness) * d.alpha)
                }
            }
        }
        return Footprint(dab: d, index: index, rect: rect, cov: cov)
    }

    /// Union of the dabs' rectangles.
    public static func strokeBounds(_ ds: [Dab]) -> PixelRect { ds.reduce(.empty) { $0.union(dabRect($1)) } }

    /// Accumulated coverage of a whole stroke: dabs build up (`c ← c + d·(ceil − c)`), capped at each
    /// dab's opacity ceiling; stroke-level masks (dual brush, texture) applied. Returns the stroke
    /// bounds and `width × height` coverage values. Uses the full brush engine.
    public static func strokeCoverage(_ stroke: Stroke) -> (PixelRect, [Float]) {
        var r = StrokeRenderer(stroke.brush, format: nil, zoom: 1)
        r.push(stroke.points)
        r.finish()
        return r.denseCoverage()
    }

    /// Composite a paint image through a coverage map onto `target`. `paint` must cover `rect`;
    /// `cov` has one value per pixel of `rect`. The per-pixel weight is `cov × opacity × selection`.
    /// Non-normal blend modes composite in straight RGBA (W3C formula).
    @discardableResult
    public static func applyCoverage(_ target: inout Surface, rect: PixelRect, cov: [Float], opacity: Float, selection: Surface?,
                                     lockTransparency: Bool, paint: Region, blend: BlendMode) -> PixelRect {
        if rect.isEmpty { return .empty }
        let fmt = target.format
        let n = fmt.channels
        var region = target.readRegion(rect)
        let w = rect.width
        let a = alphaIndex(fmt)
        let sel = selection.map { $0.readChannel0(rect) }
        var enc = [Float](repeating: 0, count: 8)
        region.withUnsafeMutableBufferPointer { reg in
            paint.data.withUnsafeBufferPointer { pd in
                for (i, c) in cov.enumerated() {
                    let x = rect.x0 + Int32(i % w), y = rect.y0 + Int32(i / w)
                    let s = sel?[i] ?? 1
                    let k = minR(c * opacity * s, 1)
                    if k <= 0 { continue }
                    let px = reg.baseAddress! + i * n
                    if lockTransparency, let a, px[a] <= 0 { continue }
                    let src = pd.baseAddress! + paint.index(x, y) * paint.ch
                    if blend == .normal {
                        overNative(fmt, px, src, k, lockTransparency)
                    } else {
                        let d = toRGBA(fmt, px)
                        let sr = toRGBA(fmt, src)
                        var o = Blend.composite(blend, backdrop: d, source: sr, opacity: k)
                        if lockTransparency { o.w = d.w }
                        enc.withUnsafeMutableBufferPointer { e in
                            _ = fromRGBA(fmt, o, into: e.baseAddress!)
                            for ch in 0..<n { px[ch] = e[ch] }
                        }
                    }
                }
            }
        }
        target.writeRegionSafe(rect, &region)
        return rect
    }

    /// Run a sequential-dab stroke: `effect(work, footprint)` edits the working copy for each dab in
    /// order; the result is mixed back at `stroke.brush.opacity × selection`. The working copy
    /// covers the stroke bounds grown by `halo` pixels so neighbourhood effects (blur, sharpen) can
    /// read around each dab; only the stroke bounds are written back. Returns the damage.
    @discardableResult
    public static func applyDabStroke(_ target: inout Surface, _ stroke: Stroke, selection: Surface?, lockTransparency: Bool, halo: Int32,
                                      _ effect: (inout Region, Footprint) -> Void) -> PixelRect {
        let ds = dabs(stroke)
        if ds.isEmpty { return .empty }
        let ctx = BrushContext(stroke.brush)
        let bounds = ds.reduce(PixelRect.empty) { $0.union(ctx.dabRect($1, dual: false)) }
        let outer = PixelRect(bounds.x0 - halo, bounds.y0 - halo, bounds.x1 + halo, bounds.y1 + halo)
        let orig = Region.read(target, outer)
        var work = orig
        for (i, d) in ds.enumerated() { effect(&work, ctx.footprint(d, index: i)) }
        mixBack(&target, orig: orig, work: work, rect: bounds, opacity: stroke.brush.opacity, selection: selection, lockTransparency: lockTransparency)
        return bounds
    }

    /// Mix a sequential-dab stroke's working pixels `work` back over the original `orig` at
    /// `opacity × selection` inside `rect`, and write that area to `target`.
    public static func mixBack(_ target: inout Surface, orig: Region, work: Region, rect: PixelRect, opacity: Float, selection: Surface?,
                               lockTransparency: Bool) {
        let fmt = target.format
        let a = alphaIndex(fmt)
        var out = orig.crop(rect)
        let n = out.ch
        let op = clampR(opacity, 0, 1)
        let sel = selection.map { $0.readChannel0(out.rect) }
        if out.rect.isEmpty { return }
        let ow = out.rect.width
        out.data.withUnsafeMutableBufferPointer { od in
            work.data.withUnsafeBufferPointer { wd in
                for y in out.rect.y0..<out.rect.y1 {
                    for x in out.rect.x0..<out.rect.x1 {
                        let li = Int(y - out.rect.y0) * ow + Int(x - out.rect.x0)
                        let k = op * (sel?[li] ?? 1)
                        if k <= 0 { continue }
                        let wv = wd.baseAddress! + work.index(x, y) * work.ch
                        let o = od.baseAddress! + li * n
                        if let a, !lockTransparency {
                            // Alpha changes: mix premultiplied, so colour under transparent pixels doesn't bleed in.
                            mixPremultiplied(UnsafeMutableBufferPointer(start: o, count: n), UnsafeBufferPointer(start: wv, count: n), a, k)
                        } else {
                            for c in 0..<n {
                                if lockTransparency && c == a { continue }
                                o[c] += (wv[c] - o[c]) * k
                            }
                        }
                    }
                }
            }
        }
        out.write(&target)
    }

    /// `dst ← lerp(dst, src, k)` in premultiplied space (straight in, straight out; `a` = alpha
    /// index). Where the result is fully transparent the colour is mixed straight.
    public static func mixPremultiplied(_ dst: UnsafeMutableBufferPointer<Float>, _ src: UnsafeBufferPointer<Float>, _ a: Int, _ k: Float) {
        guard a < dst.count, a < src.count else { return }
        let da = dst[a], sa = src[a]
        let oa = da + (sa - da) * k
        for c in 0..<min(dst.count, src.count) where c != a {
            dst[c] = oa > 1e-6 ? (dst[c] * da + (src[c] * sa - dst[c] * da) * k) / oa : dst[c] + (src[c] - dst[c]) * k
        }
        dst[a] = oa
    }

    public static func mixPremultiplied(_ dst: inout [Float], _ src: [Float], _ a: Int, _ k: Float) {
        dst.withUnsafeMutableBufferPointer { d in src.withUnsafeBufferPointer { s in mixPremultiplied(d, s, a, k) } }
    }

    /// Premultiply a straight pixel in place (no-op without alpha).
    static func premultiply(_ px: inout [Float], _ alpha: Int?) {
        guard let a = alpha, a < px.count else { return }
        let pa = px[a]
        for c in px.indices where c != a { px[c] *= pa }
    }
}

/// Smudge state: a colour buffer carried from dab to dab (centred on the dab), which is laid down
/// at `strength` and then re-picks-up the pixels under the dab. Use with `Retouch.applyDabStroke`.
public struct Smudge: Sendable {
    /// 0…1: how much carried colour each dab lays down (and keeps).
    public var strength: Float
    /// Finger painting: start the stroke with this native-channel colour.
    public var finger: [Float]?
    var radius: Int32
    /// Alpha channel index: when set, the carried colour is premultiplied.
    var alpha: Int?
    /// Carried colour (premultiplied when `alpha` is set).
    var carry: [Float]?

    public init(strength: Float, finger: [Float]?, maxBrushSize: Float) {
        self.strength = clampR(strength, 0, 1)
        self.finger = finger
        radius = asI32((maxBrushSize / 2).rounded(.up)) &+ 2
    }

    /// Mix in premultiplied space using alpha channel `a` (the format's `alphaIndex`).
    public func withAlpha(_ a: Int?) -> Smudge {
        var s = self
        s.alpha = a
        return s
    }

    /// Apply one dab to the working copy.
    public mutating func dab(_ work: inout Region, _ fp: Footprint) {
        let r = radius, n = work.ch
        let side = Int(2 * r + 1)
        let cx = asI32(fp.dab.center.x.rounded(.down)), cy = asI32(fp.dab.center.y.rounded(.down))
        let wr = work.rect
        let alpha = self.alpha.flatMap { $0 < n ? $0 : nil }
        func clampPx(_ x: Int32, _ y: Int32) -> [Float] {
            var v = Array(work.px(min(max(x, wr.x0), wr.x1 - 1), min(max(y, wr.y0), wr.y1 - 1)))
            Retouch.premultiply(&v, alpha)
            return v
        }
        if carry == nil {
            var c = [Float](repeating: 0, count: side * side * n)
            for qy in 0..<side {
                for qx in 0..<side {
                    let v: [Float]
                    if var f = finger {
                        if f.count < n { f.append(contentsOf: repeatElement(1, count: n - f.count)) } else { f = Array(f[0..<n]) }
                        Retouch.premultiply(&f, alpha)
                        v = f
                    } else {
                        v = clampPx(cx + Int32(qx) - r, cy + Int32(qy) - r)
                    }
                    for k in 0..<n { c[(qy * side + qx) * n + k] = v[k] }
                }
            }
            carry = c
        }
        // Lay down the carried colour.
        let ys = max(fp.rect.y0, wr.y0), ye = min(fp.rect.y1, wr.y1)
        let xs = max(fp.rect.x0, wr.x0), xe = min(fp.rect.x1, wr.x1)
        if ys < ye && xs < xe {
            for y in ys..<ye {
                for x in xs..<xe {
                    let k = fp.at(x, y) * strength
                    let qx = x - cx + r, qy = y - cy + r
                    if k <= 0 || qx < 0 || qy < 0 || qx >= Int32(side) || qy >= Int32(side) { continue }
                    let q = (Int(qy) * side + Int(qx)) * n
                    let cr = carry!
                    work.withPixel(x, y) { px in
                        if let a = alpha {
                            // Back to straight for the mix (premultiplied lerp towards the carried colour).
                            let ca = cr[q + a]
                            var src = Array(cr[q..<q + n])
                            if ca > 1e-6 { for c in 0..<n where c != a { src[c] /= ca } }
                            src.withUnsafeBufferPointer { Retouch.mixPremultiplied(px, $0, a, k) }
                        } else {
                            for c in 0..<n { px[c] += (cr[q + c] - px[c]) * k }
                        }
                    }
                }
            }
        }
        // Pick up: the carried colour keeps `strength` of itself.
        let keep = strength
        for qy in 0..<side {
            for qx in 0..<side {
                let x = cx + Int32(qx) - r, y = cy + Int32(qy) - r
                if !wr.contains(x: x, y: y) { continue }
                let q = (qy * side + qx) * n
                let base = work.index(x, y) * n
                let pa: Float = alpha.map { work.data[base + $0] } ?? 1
                for c in 0..<n {
                    let pv = work.data[base + c]
                    let v = (alpha != nil && alpha != c) ? pv * pa : pv
                    carry![q + c] = carry![q + c] * keep + v * (1 - keep)
                }
            }
        }
    }
}
