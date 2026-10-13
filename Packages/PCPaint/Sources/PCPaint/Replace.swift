// Port of photocraft-paint (crates/paint/src/replace.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Color Replacement: recolour pixels similar to a sampled colour using a non-separable blend
// (Hue, Saturation, Color or Luminosity) with the foreground colour.

import PCFoundation

public enum ReplaceMode: String, Codable, Sendable, CaseIterable { case hue, saturation, color, luminosity }

public enum Sampling: String, Codable, Sendable, CaseIterable {
    /// Resample under the brush centre at every dab.
    case continuous
    /// Sample once, where the stroke starts.
    case once
    /// Replace only colours near the background swatch.
    case backgroundSwatch
}

public enum Limits: String, Codable, Sendable, CaseIterable {
    /// Matching pixels anywhere under the brush.
    case discontiguous
    /// Matching pixels connected to the brush centre.
    case contiguous
    /// Contiguous, and stop at edges (no soft tolerance falloff).
    case findEdges
}

public struct ReplaceSettings: Hashable, Sendable {
    public var mode: ReplaceMode = .color
    public var sampling: Sampling = .continuous
    public var limits: Limits = .contiguous
    /// 0…1 (max per-channel RGB distance).
    public var tolerance: Float = 0.3
    public var antiAlias = true
    /// Replacement (foreground) colour, straight RGBA.
    public var color: SIMD4<Float> = SIMD4(1, 0, 0, 1)
    /// Background swatch for `Sampling.backgroundSwatch`.
    public var background: SIMD4<Float> = SIMD4(1, 1, 1, 1)

    public init(mode: ReplaceMode = .color, sampling: Sampling = .continuous, limits: Limits = .contiguous, tolerance: Float = 0.3,
                antiAlias: Bool = true, color: SIMD4<Float> = SIMD4(1, 0, 0, 1), background: SIMD4<Float> = SIMD4(1, 1, 1, 1)) {
        self.mode = mode; self.sampling = sampling; self.limits = limits; self.tolerance = tolerance
        self.antiAlias = antiAlias; self.color = color; self.background = background
    }
}

extension ReplaceSettings: Codable {
    enum CodingKeys: String, CodingKey { case mode, sampling, limits, tolerance, antiAlias, color, background }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReplaceSettings()
        self.init(mode: try c.get(.mode, d.mode), sampling: try c.get(.sampling, d.sampling), limits: try c.get(.limits, d.limits),
                  tolerance: try c.get(.tolerance, d.tolerance), antiAlias: try c.get(.antiAlias, d.antiAlias),
                  color: try c.get(.color, d.color), background: try c.get(.background, d.background))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode); try c.encode(sampling, forKey: .sampling); try c.encode(limits, forKey: .limits)
        try c.encode(tolerance, forKey: .tolerance); try c.encode(antiAlias, forKey: .antiAlias); try c.encode(color, forKey: .color)
        try c.encode(background, forKey: .background)
    }
}

/// Zeroes the weights not 4-connected to `(sx, sy)` through non-zero weights.
func keepConnected(_ weight: inout [Float], _ w: Int, _ h: Int, _ sx: Int, _ sy: Int) {
    var keep = [Bool](repeating: false, count: w * h)
    let si = sy * w + sx
    if si < weight.count && weight[si] > 0 {
        var stack = [si]
        keep[si] = true
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            func nb(_ j: Int) {
                if !keep[j] && weight[j] > 0 { keep[j] = true; stack.append(j) }
            }
            if x > 0 { nb(i - 1) }
            if x + 1 < w { nb(i + 1) }
            if y > 0 { nb(i - w) }
            if y + 1 < h { nb(i + w) }
        }
    }
    for i in weight.indices where !keep[i] { weight[i] = 0 }
}

public enum ColorReplacement {
    static func dist(_ a: SIMD4<Float>, _ b: SIMD3<Float>) -> Float {
        maxR(maxR(abs(a.x - b.x), abs(a.y - b.y)), abs(a.z - b.z))
    }

    /// Replace colours along a stroke. Returns the damaged rectangle.
    @discardableResult
    public static func apply(_ target: inout Surface, _ stroke: Stroke, _ rs: ReplaceSettings, selection: Surface?, lockTransparency: Bool) -> PixelRect {
        var effect = Effect(pre: target, rs)
        return Retouch.applyDabStroke(&target, stroke, selection: selection, lockTransparency: lockTransparency, halo: 0) { work, fp in
            effect.apply(&work, fp)
        }
    }

    /// One Color Replacement dab's edit of a working copy, matching against `pre` (the target before
    /// the stroke). Shared by `apply` and live previews that run the dabs as they come.
    public struct Effect: Sendable {
        let pre: Surface
        let rs: ReplaceSettings
        let mode: BlendMode
        let tol: Float
        let soft: Bool
        var once: SIMD3<Float>?

        public init(pre: Surface, _ rs: ReplaceSettings) {
            self.pre = pre
            self.rs = rs
            switch rs.mode {
            case .hue: mode = .hue
            case .saturation: mode = .saturation
            case .color: mode = .color
            case .luminosity: mode = .luminosity
            }
            tol = clampR(rs.tolerance, 0, 1)
            soft = rs.antiAlias && rs.limits != .findEdges
        }

        func matchWeight(_ d: Float) -> Float {
            if d > tol { return 0 }
            if soft && tol > 0 { return clampR((tol - d) / (tol * 0.25), 0, 1) }  // soft falloff over the last quarter
            return 1
        }

        public mutating func apply(_ work: inout Region, _ fp: Footprint) {
            let fmt = pre.format
            let n = fmt.channels
            let fg = SIMD3(rs.color.x, rs.color.y, rs.color.z)
            let cx = asI32(fp.dab.center.x.rounded(.down)), cy = asI32(fp.dab.center.y.rounded(.down))
            let sampled: SIMD3<Float>
            switch rs.sampling {
            case .continuous:
                let c = pre.rgba(cx, cy)
                sampled = SIMD3(c.x, c.y, c.z)
            case .once:
                if once == nil {
                    let c = pre.rgba(cx, cy)
                    once = SIMD3(c.x, c.y, c.z)
                }
                sampled = once!
            case .backgroundSwatch:
                sampled = SIMD3(rs.background.x, rs.background.y, rs.background.z)
            }
            let r = fp.rect.intersect(work.rect)
            if r.isEmpty { return }
            let w = r.width, h = r.height
            // Match against the pre-stroke colours, so pixels recoloured by earlier dabs of this
            // stroke still count as the sampled colour.
            let preRGBA = pre.readRGBA(r)
            var weight = [Float](repeating: 0, count: w * h)
            for y in r.y0..<r.y1 {
                for x in r.x0..<r.x1 {
                    if fp.at(x, y) <= 0 { continue }
                    let i = Int(y - r.y0) * w + Int(x - r.x0)
                    let c = preRGBA[i]
                    if c.w <= 0 { continue }
                    weight[i] = matchWeight(ColorReplacement.dist(c, sampled))
                }
            }
            if rs.limits != .discontiguous {
                // Keep only the region connected to the centre (4-connected flood fill).
                keepConnected(&weight, w, h, Int(min(max(cx, r.x0), r.x1 - 1) - r.x0), Int(min(max(cy, r.y0), r.y1 - 1) - r.y0))
            }
            var enc = [Float](repeating: 0, count: 8)
            for y in r.y0..<r.y1 {
                for x in r.x0..<r.x1 {
                    let k = fp.at(x, y) * weight[Int(y - r.y0) * w + Int(x - r.x0)]
                    if k <= 0 { continue }
                    work.withPixel(x, y) { px in
                        let c = toRGBA(fmt, px.baseAddress!)
                        let b = Blend.rgb(mode, SIMD3(c.x, c.y, c.z), fg)
                        let o = SIMD4(c.x + (b.x - c.x) * k, c.y + (b.y - c.y) * k, c.z + (b.z - c.z) * k, c.w)
                        enc.withUnsafeMutableBufferPointer { e in
                            _ = fromRGBA(fmt, o, into: e.baseAddress!)
                            for ch in 0..<n { px[ch] = e[ch] }
                        }
                    }
                }
            }
        }
    }
}
