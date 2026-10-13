// Port of photocraft-algo's selection core the engine needs before PCAlgo lands (crates/algo/src/selection.rs `SelectionMode`, `mask_from_surface`, `mask_to_surface`, `combine`; selection/marquee.rs `ellipse_surface`, `combine_surfaces`; selection_blur.rs reference `feather`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Selections are GRAY8 coverage surfaces. These are the CPU reference versions; PCAlgo's tuned
// (and Metal) versions replace them through the same signatures when it is finished.

import Foundation
import PCDocument
import PCFoundation

public enum SelectionMath {
    /// How a new selection combines with the current one.
    public enum Mode: String, Sendable, CaseIterable {
        case replace, add, subtract, intersect
        /// `replace|add|subtract|intersect` (unknown → replace).
        public static func parse(_ s: String) -> Mode { Mode(rawValue: s) ?? .replace }
    }

    /// Coverage of a selection over `area`, row-major (no selection → zeros).
    public static func mask(from s: Surface?, _ area: PixelRect) -> [Float] {
        guard let s else { return [Float](repeating: 0, count: area.area) }
        return s.coverage(area)
    }

    /// The 8-bit selection value of a coverage (clamped, rounded, NaN → 0).
    static func q8(_ v: Float) -> Float {
        if v.isNaN { return 0 }
        return (min(max(v, 0), 1) * 255 + 0.5).rounded(.down) / 255
    }

    /// A GRAY8 selection from a mask over `area`; nil when nothing is selected.
    public static func surface(_ m: [Float], _ area: PixelRect) -> Surface? {
        var s = Surface(format: .gray8)
        if area.isEmpty { return nil }
        s.writeRegion(area, m)
        s.prune()
        return s.tileCount > 0 ? s : nil
    }

    /// Combines a new mask with the old selection (photocraft `combine`).
    public static func combine(_ old: Surface?, _ new: [Float], _ area: PixelRect, _ mode: Mode) -> Surface? {
        if area.isEmpty { return nil }
        switch mode {
        case .replace:
            return surface(new, area)
        case .add, .subtract, .intersect:
            let prev = mask(from: old, area)
            var out = [Float](repeating: 0, count: new.count)
            for i in out.indices {
                let p = prev[i], v = q8(new[i])
                switch mode {
                case .add: out[i] = max(p, v)
                case .subtract: out[i] = max(p - v, 0)
                default: out[i] = min(p, v)
                }
            }
            return surface(out, area)
        }
    }

    /// Combines a shape selection with the old one as the marquee does: with no existing
    /// selection, subtract and intersect select nothing; nothing on the canvas deselects.
    public static func combineShape(_ old: Surface?, _ shape: Surface, _ area: PixelRect, _ mode: Mode) -> Surface? {
        let combined: Surface
        switch (mode, old) {
        case (.add, let o?): combined = combineSurfaces(o, shape, area) { max($0, $1) }
        case (.subtract, let o?): combined = combineSurfaces(o, shape, area) { $0 * (1 - $1) }
        case (.intersect, let o?): combined = combineSurfaces(o, shape, area) { min($0, $1) }
        case (.subtract, nil), (.intersect, nil): combined = Surface(format: .gray8)
        default: combined = shape
        }
        return combined.contentBounds.isEmpty ? nil : combined
    }

    /// Per-pixel combination of two selections over `area` (photocraft `combine_surfaces`).
    public static func combineSurfaces(_ a: Surface, _ b: Surface, _ area: PixelRect, _ f: (Float, Float) -> Float) -> Surface {
        let ma = a.coverage(area), mb = b.coverage(area)
        var out = Surface(format: .gray8)
        out.writeRegion(area, zip(ma, mb).map { f($0, $1) })
        out.prune()
        return out
    }

    /// An ellipse inscribed in `r`, cut at `area`: anti-aliased with 4×4 sub-samples per edge
    /// pixel, exactly as the Elliptical Marquee (photocraft `ellipse_surface`).
    public static func ellipseSurface(_ r: PixelRect, area: PixelRect, antiAlias aa: Bool) -> Surface {
        var out = Surface(format: .gray8)
        let clip = r.intersect(area)
        if clip.isEmpty { return out }
        let cx = Float(Int64(r.x0) + Int64(r.x1)) / 2, cy = Float(Int64(r.y0) + Int64(r.y1)) / 2
        let rx = Float(r.width) / 2, ry = Float(r.height) / 2
        func inside(_ x: Float, _ y: Float) -> Bool {
            let dx = (x - cx) / rx, dy = (y - cy) / ry
            return dx * dx + dy * dy <= 1
        }
        let w = clip.width
        var m = [Float](repeating: 0, count: clip.area)
        for yy in 0..<clip.height {
            let y = clip.y0 + Int32(yy), fy = Float(y)
            for xx in 0..<w {
                let x = clip.x0 + Int32(xx), fx = Float(x)
                var cov: Int
                if !aa {
                    cov = inside(fx + 0.5, fy + 0.5) ? 16 : 0
                } else if inside(fx, fy) && inside(fx + 1, fy) && inside(fx, fy + 1) && inside(fx + 1, fy + 1) {
                    cov = 16
                } else {
                    cov = 0
                    for i in 0..<16 where inside(fx + (Float(i % 4) + 0.5) / 4, fy + (Float(i / 4) + 0.5) / 4) { cov += 1 }
                }
                m[yy * w + xx] = Float(cov) / 16
            }
        }
        out.writeRegion(clip, m)
        out.prune()
        return out
    }

    /// Feather: Gaussian blur of the mask with σ = radius, kernel truncated at 3σ, zero beyond the
    /// canvas (photocraft `selection_blur` reference `feather`).
    public static func feather(_ m: [Float], _ w: Int, _ h: Int, _ radius: Float) -> [Float] {
        guard radius > 0, w > 0, h > 0, m.count == w * h else { return m }
        let sigma = radius
        let k = Int((3 * sigma).rounded(.up))
        let raw = (-k...k).map { i in expf(-Float(i * i) / (2 * sigma * sigma)) }
        let sum = raw.reduce(0, +)
        let kernel = raw.map { $0 / sum }
        var tmp = [Float](repeating: 0, count: m.count)
        tmp.withUnsafeMutableBufferPointer { tp in
            let t = SendableBuffer(tp)
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    var acc: Float = 0
                    for (j, kv) in kernel.enumerated() {
                        let xx = x + j - k
                        if xx >= 0 && xx < w { acc += m[y * w + xx] * kv }
                    }
                    t[y * w + x] = acc
                }
            }
        }
        var out = [Float](repeating: 0, count: m.count)
        out.withUnsafeMutableBufferPointer { op in
            let o = SendableBuffer(op)
            let src = tmp
            DispatchQueue.concurrentPerform(iterations: w) { x in
                for y in 0..<h {
                    var acc: Float = 0
                    for (j, kv) in kernel.enumerated() {
                        let yy = y + j - k
                        if yy >= 0 && yy < h { acc += src[yy * w + x] * kv }
                    }
                    o[y * w + x] = acc
                }
            }
        }
        return out
    }
}
