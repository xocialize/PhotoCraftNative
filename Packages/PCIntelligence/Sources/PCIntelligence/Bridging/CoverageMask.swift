// Coverage masks in document space, and how a found region combines with the current selection.
// Selection coverage, soft edges and the combine modes follow photocraft-algo
// (crates/algo/src/selection.rs `SelectionMode`, `combine_region`): replace, add (max), subtract
// (saturating) and intersect (min), quantised to the 8-bit grid GRAY8 selections are stored on,
// tiles that hold nothing pruned, and "nothing selected" as nil. MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

import CoreGraphics
import PCFoundation

/// How a new selection combines with the current one (photocraft `SelectionMode`; JSON camelCase).
public enum SelectionMode: String, Sendable, Codable, CaseIterable {
    case replace, add, subtract, intersect

    /// Parses `replace|add|subtract|intersect`, with `new` as photocraft's alias of replace; unknown
    /// values are replace, as in photocraft.
    public init(parsing s: String) {
        self = s == "new" ? .replace : SelectionMode(rawValue: s) ?? .replace
    }
}

/// A coverage plane (0…1, row-major, white = covered) over a rectangle of document space. Outside
/// the rectangle coverage is 0.
public struct CoverageMask: Sendable, Equatable {
    public var rect: PixelRect
    public var values: [Float]

    public init(rect: PixelRect, values: [Float]) {
        precondition(values.count == rect.area, "CoverageMask: \(values.count) values for a \(rect.width)×\(rect.height) rect")
        self.rect = rect
        self.values = values
    }

    /// A uniform mask.
    public init(rect: PixelRect, fill: Float) {
        self.rect = rect
        values = [Float](repeating: fill, count: rect.area)
    }

    /// The first channel of `surface` over `rect` (a selection, layer mask or channel).
    public init(surface: Surface, rect: PixelRect) {
        let ch = surface.channels
        let raw = surface.readRegion(rect)
        self.rect = rect
        values = ch == 1 ? raw : stride(from: 0, to: raw.count, by: ch).map { raw[$0] }
    }

    /// A Kit mask image placed at `rect` (resampled to its size when the image differs).
    public init(image: CGImage, rect: PixelRect) throws {
        self.rect = rect
        values = try KitBridge.coverage(from: image, width: rect.width, height: rect.height)
    }

    /// Coverage at document pixel (x, y); 0 outside `rect`.
    public subscript(x: Int32, y: Int32) -> Float {
        guard rect.contains(x: x, y: y) else { return 0 }
        return values[Int(y - rect.y0) * rect.width + Int(x - rect.x0)]
    }

    /// Tight bounds of the covered pixels (coverage > 0), in document space.
    public var bounds: PixelRect {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        let w = rect.width
        for y in 0..<rect.height {
            let row = y * w
            for x in 0..<w where values[row + x] > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .empty }
        return PixelRect(x0: rect.x0 + Int32(minX), y0: rect.y0 + Int32(minY), x1: rect.x0 + Int32(maxX + 1), y1: rect.y0 + Int32(maxY + 1))
    }

    /// Nothing is covered.
    public var isEmpty: Bool { !values.contains { $0 > 0 } }

    /// Covered area in pixels (sum of coverage).
    public var area: Double { values.reduce(0) { $0 + Double($1) } }

    /// This mask over `r` (0 where it has no value).
    public func cropped(to r: PixelRect) -> CoverageMask {
        var out = CoverageMask(rect: r, fill: 0)
        let inter = rect.intersect(r)
        guard !inter.isEmpty else { return out }
        for y in inter.y0..<inter.y1 {
            let src = Int(y - rect.y0) * rect.width + Int(inter.x0 - rect.x0)
            let dst = Int(y - r.y0) * r.width + Int(inter.x0 - r.x0)
            for i in 0..<inter.width { out.values[dst + i] = values[src + i] }
        }
        return out
    }

    /// 1 where coverage exceeds `threshold`, else 0 (photocraft's hole test is coverage > 0).
    public func binarized(threshold: Float = 0) -> CoverageMask {
        CoverageMask(rect: rect, values: values.map { $0 > threshold ? 1 : 0 })
    }

    /// Per-pixel product with `other` (0 where `other` has no value).
    public func multiplied(by other: CoverageMask) -> CoverageMask {
        let o = other.rect == rect ? other : other.cropped(to: rect)
        return CoverageMask(rect: rect, values: zip(values, o.values).map { $0 * $1 })
    }

    /// Quantised to the 8-bit grid GRAY8 selections are stored on.
    public func quantized8() -> CoverageMask {
        CoverageMask(rect: rect, values: values.map { Float(KitBridge.q8($0)) / 255 })
    }

    /// A Gray coverage surface at `sample` depth (no alpha, default 0) positioned in document space,
    /// with empty tiles pruned. nil when nothing is covered.
    public func surface(sample: SampleType = .u8) -> Surface? {
        guard !rect.isEmpty, !isEmpty else { return nil }
        var s = Surface(format: PixelFormat(mode: .grayscale, sample: sample, alpha: false))
        s.writeRegion(rect, values)
        s.prune()
        return s.tileCount > 0 ? s : nil
    }

    /// A DeviceGray mask image of this plane for the Kits (white = covered).
    public func image(sample: SampleType = .u8) throws -> CGImage {
        try KitBridge.maskImage(values, width: rect.width, height: rect.height, sample: sample)
    }

    /// Combines `new` with the current selection `old` by `mode`, as photocraft's `combine_region`:
    /// outside `new.rect` the new coverage is 0, so replace and intersect keep nothing there while add
    /// and subtract keep the old selection. Returns nil when nothing remains selected. The result is
    /// a Gray surface at `sample` depth (photocraft stores selections as GRAY8, the default).
    public static func combine(_ new: CoverageMask?, with old: Surface?, mode: SelectionMode,
                               sample: SampleType = .u8) -> Surface? {
        let n = (sample == .u8 ? new?.quantized8() : new) ?? CoverageMask(rect: .empty, values: [])
        let format = PixelFormat(mode: .grayscale, sample: sample, alpha: false)
        func nonEmpty(_ s: Surface) -> Surface? { s.contentBounds.isEmpty ? nil : s }
        switch (mode, old) {
        case (.replace, _), (.add, nil):
            return n.surface(sample: sample)
        case (.subtract, nil), (.intersect, nil):
            return nil
        case (.intersect, let o?):
            let prev = CoverageMask(surface: o, rect: n.rect)
            return CoverageMask(rect: n.rect, values: zip(prev.values, n.values).map { min($0, $1) }).surface(sample: sample)
        case (.add, let o?), (.subtract, let o?):
            var s = o.format == format ? o : convertedCoverage(o, to: format)
            if n.rect.isEmpty { return nonEmpty(s) }
            let prev = CoverageMask(surface: o, rect: n.rect)
            let out = zip(prev.values, n.values).map { mode == .add ? max($0, $1) : max($0 - $1, 0) }
            s.writeRegion(n.rect, out)
            s.prune()
            return nonEmpty(s)
        }
    }

    /// `s`'s first channel as a surface of `format` (a Gray coverage format).
    static func convertedCoverage(_ s: Surface, to format: PixelFormat) -> Surface {
        if s.format.mode == format.mode && s.format.alpha == format.alpha { return s.converted(to: format) }
        var out = Surface(format: format, defaultPixel: [s.defaultPixelValue.first ?? 0])
        s.forEachTile { c, _ in
            let r = c.rect
            out.writeRegion(r, CoverageMask(surface: s, rect: r).values)
        }
        return out
    }
}
