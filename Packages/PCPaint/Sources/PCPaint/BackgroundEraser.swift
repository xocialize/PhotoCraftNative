// Port of photocraft-paint (crates/paint/src/bg_erase.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Background Eraser: along a stroke, sample the colour under the brush hotspot and erase pixels of
// similar colour inside the brush to transparency. Colours are compared in the surface's own
// colour channels (RGB, CMYK, Gray, Lab… at any depth), so nothing is converted through RGB; only
// alpha changes.

import PCFoundation

public struct BgEraseSettings: Hashable, Sendable {
    public var sampling: Sampling = .continuous
    public var limits: Limits = .contiguous
    /// 0…1: largest per-channel difference from the sampled colour that is erased.
    public var tolerance: Float = 0.5
    /// Keep pixels that match the foreground colour.
    public var protectForeground = false
    /// Straight RGBA foreground colour (for Protect Foreground Color).
    public var foreground: SIMD4<Float> = SIMD4(0, 0, 0, 1)
    /// Straight RGBA background swatch (for `Sampling.backgroundSwatch`).
    public var background: SIMD4<Float> = SIMD4(1, 1, 1, 1)

    public init(sampling: Sampling = .continuous, limits: Limits = .contiguous, tolerance: Float = 0.5, protectForeground: Bool = false,
                foreground: SIMD4<Float> = SIMD4(0, 0, 0, 1), background: SIMD4<Float> = SIMD4(1, 1, 1, 1)) {
        self.sampling = sampling; self.limits = limits; self.tolerance = tolerance; self.protectForeground = protectForeground
        self.foreground = foreground; self.background = background
    }
}

extension BgEraseSettings: Codable {
    enum CodingKeys: String, CodingKey { case sampling, limits, tolerance, protectForeground, foreground, background }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BgEraseSettings()
        self.init(sampling: try c.get(.sampling, d.sampling), limits: try c.get(.limits, d.limits), tolerance: try c.get(.tolerance, d.tolerance),
                  protectForeground: try c.get(.protectForeground, d.protectForeground), foreground: try c.get(.foreground, d.foreground),
                  background: try c.get(.background, d.background))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sampling, forKey: .sampling); try c.encode(limits, forKey: .limits); try c.encode(tolerance, forKey: .tolerance)
        try c.encode(protectForeground, forKey: .protectForeground); try c.encode(foreground, forKey: .foreground)
        try c.encode(background, forKey: .background)
    }
}

public enum BackgroundEraser {
    /// Largest per-channel difference over the colour channels.
    static func dist(_ a: UnsafeBufferPointer<Float>, _ b: [Float]) -> Float {
        var m: Float = 0
        for i in 0..<min(a.count, b.count) { m = maxR(m, abs(a[i] - b[i])) }
        return m
    }

    /// Erase along `stroke`. The brush opacity is ignored (Photoshop's Background Eraser has none);
    /// the selection limits the effect. Returns the damage; empty when the surface has no alpha.
    @discardableResult
    public static func apply(_ target: inout Surface, _ stroke: Stroke, _ bs: BgEraseSettings, selection: Surface?) -> PixelRect {
        let fmt = target.format
        guard let a = alphaIndex(fmt) else { return .empty }
        let nc = a
        let tol: Float = bs.tolerance.isFinite ? clampR(bs.tolerance, 0, 1) : 0
        let soft = bs.limits != .findEdges
        func native(_ c: SIMD4<Float>) -> [Float] { Array(fromRGBA(fmt, SIMD4(c.x, c.y, c.z, 1))[0..<nc]) }
        let swatch = native(bs.background)
        let fg = native(bs.foreground)
        var once: [Float]??
        func matchWeight(_ d: Float) -> Float {
            if d > tol { return 0 }
            if soft && tol > 0 { return clampR((tol - d) / (tol * 0.25), 0, 1) }
            return 1
        }
        var st = stroke
        st.brush.opacity = 1
        st.brush.erase = false
        return Retouch.applyDabStroke(&target, st, selection: selection, lockTransparency: false, halo: 0) { work, fp in
            let r = fp.rect.intersect(work.rect)
            if r.isEmpty { return }
            let cx = asI32(fp.dab.center.x.rounded(.down)), cy = asI32(fp.dab.center.y.rounded(.down))
            // The hotspot's colour (nil where it is already transparent or off the working area).
            func hotspot() -> [Float]? {
                if !work.rect.contains(x: cx, y: cy) { return nil }
                let p = work.px(cx, cy)
                return p[p.startIndex + a] > 0 ? Array(p.prefix(nc)) : nil
            }
            let sampled: [Float]?
            switch bs.sampling {
            case .continuous: sampled = hotspot()
            case .once:
                if once == nil { once = .some(hotspot()) }
                sampled = once!
            case .backgroundSwatch: sampled = swatch
            }
            guard let sampled else { return }
            let w = r.width, h = r.height
            // Erasing only lowers alpha, so the working copy still holds the pre-stroke colours.
            var weight = [Float](repeating: 0, count: w * h)
            let ch = work.ch
            work.data.withUnsafeBufferPointer { wd in
                for y in r.y0..<r.y1 {
                    for x in r.x0..<r.x1 {
                        if fp.at(x, y) <= 0 { continue }
                        let base = work.index(x, y) * ch
                        if wd[base + a] <= 0 { continue }
                        let c = UnsafeBufferPointer(rebasing: wd[base..<base + nc])
                        if bs.protectForeground && dist(c, fg) <= tol { continue }
                        weight[Int(y - r.y0) * w + Int(x - r.x0)] = matchWeight(dist(c, sampled))
                    }
                }
            }
            if bs.limits != .discontiguous {
                keepConnected(&weight, w, h, Int(min(max(cx, r.x0), r.x1 - 1) - r.x0), Int(min(max(cy, r.y0), r.y1 - 1) - r.y0))
            }
            for y in r.y0..<r.y1 {
                for x in r.x0..<r.x1 {
                    let k = fp.at(x, y) * weight[Int(y - r.y0) * w + Int(x - r.x0)]
                    if k <= 0 { continue }
                    work.withPixel(x, y) { p in
                        p[a] *= 1 - minR(k, 1)
                        if p[a] <= 0 { for i in p.indices { p[i] = 0 } }
                    }
                }
            }
        }
    }
}
