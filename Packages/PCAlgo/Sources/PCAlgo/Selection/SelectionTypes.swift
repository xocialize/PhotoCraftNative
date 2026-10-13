// Port of photocraft-algo (crates/algo/src/selection.rs: SelectionMode, Region, RangeSample, LabRange), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Value types of the selection API: how a new selection combines with the current one, an
// 8-bit selected region, Color Range samples and the Lab box of Color Range › Sampled Colors.

import PCFoundation

/// How a new selection combines with the current one (photocraft `SelectionMode`).
public enum SelectionMode: String, Codable, Sendable, Hashable, CaseIterable {
    case replace, add, subtract, intersect

    /// Parses `replace|add|subtract|intersect` (unknown → replace).
    public static func parse(_ s: String) -> SelectionMode { SelectionMode(rawValue: s) ?? .replace }
}

/// A selected region: 8-bit coverage over `bbox` (row-major), the bounding box of the pixels
/// touched (including the anti-aliased fringe) — photocraft `selection::Region`.
public struct SelectionRegion: Sendable, Hashable {
    public var bbox: PixelRect
    public var mask: [UInt8]

    public init(bbox: PixelRect, mask: [UInt8]) { self.bbox = bbox; self.mask = mask }

    /// Coverage (0–1) at document pixel `(x, y)`; zero outside the box.
    public func at(_ x: Int32, _ y: Int32) -> Float {
        if !bbox.contains(x: x, y: y) { return 0 }
        return Float(mask[Int(y - bbox.y0) * bbox.width + Int(x - bbox.x0)]) / 255
    }
}

/// One Color Range sample (Sampled Colors): an eyedropper colour, and where it was picked
/// (area-local pixel coordinates; needed for Localized Color Clusters).
public struct RangeSample: Sendable, Hashable {
    public var color: SIMD3<Float>
    public var at: SIMD2<Float>?
    public init(color: SIMD3<Float>, at: SIMD2<Float>? = nil) { self.color = color; self.at = at }
}

/// The colours of Color Range › Sampled Colors: the Lab box spanned by the eyedropper samples
/// (photocraft `LabRange`). CIE Lab (D50): L 0–100, a and b about −128–127.
public struct LabRange: Sendable, Hashable {
    public var lo: SIMD3<Float>
    public var hi: SIMD3<Float>

    public init(lo: SIMD3<Float>, hi: SIMD3<Float>) { self.lo = lo; self.hi = hi }

    /// The box around one colour.
    public static func point(_ lab: SIMD3<Float>) -> LabRange { LabRange(lo: lab, hi: lab) }

    /// The box spanning `colors`, nil when there are none.
    public static func spanning(_ colors: [SIMD3<Float>]) -> LabRange? {
        guard let first = colors.first else { return nil }
        return colors.reduce(point(first)) { $0.grow($1) }
    }

    /// "Add to Sample": the box grows to take `lab` in (Rust `f32::min`/`max`: NaN ignored).
    public func grow(_ lab: SIMD3<Float>) -> LabRange {
        var r = self
        for k in 0..<3 {
            r.lo[k] = Float.minimum(lo[k], lab[k])
            r.hi[k] = Float.maximum(hi[k], lab[k])
        }
        return r
    }

    /// "Subtract from Sample" the way Photoshop does it (photocraft `LabRange::subtract`): each
    /// Lab axis on its own, with `w` the axis's width at `fuzziness` (L: fuzziness/2.55, a and b:
    /// a third of fuzziness·256/255) and q = w/5. Inside the box the nearer edge moves onto the
    /// value (the upper one on a tie); on an edge or outside by less than w, that edge moves in to
    /// the first of m + q … m + 5q beyond it; further out nothing changes.
    public func subtract(_ lab: SIMD3<Float>, fuzziness: Float) -> LabRange {
        let fz: Float = fuzziness.isFinite ? Float.maximum(fuzziness, 0) : 0
        var r = self
        for k in 0..<3 {
            let m = lab[k]
            // Measured: the lightness step has no 256/255 factor, the a/b steps do.
            let w: Float = k == 0 ? fz / 2.55 : fz * 256 / 255 / 3
            let lo = r.lo[k], hi = r.hi[k]
            if !m.isFinite { continue }
            if m > lo && m < hi {
                if m - lo < hi - m { r.lo[k] = m } else { r.hi[k] = m }
                continue
            }
            let q = w / 5
            if q <= 0 { continue }
            let d = m <= lo ? lo - m : m - hi
            let n = (d / q).rounded(.down) + 1
            if n > 5 { continue }
            if m <= lo { r.lo[k] = Float.minimum(m + n * q, hi) } else { r.hi[k] = Float.maximum(m - n * q, lo) }
        }
        return r
    }
}
