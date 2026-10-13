// Port of photocraft-algo (crates/algo/src/paint.rs: bucket_fill, bucket_fill_src, bucket_fill_region_src, composite_area), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Paint Bucket: the 8-bit magic wand region of the seed pixel (on the layer's own pixels, or a
// region sampled elsewhere, e.g. from the composite), composited with a colour or a pattern at
// `coverage × opacity × selection`, Normal mode, in straight sRGB converted to and from the
// surface's model as the Gradient tool does. Only the region's box is visited, tile by tile, and
// tiles with no coverage are left untouched (their storage is never materialised or copied).

import Foundation
import PCFoundation

/// Paint Bucket (photocraft `paint::bucket_fill*`).
public enum PaintBucket {
    /// Fills the region similar to `seed` within `area` with `color` (photocraft `bucket_fill`).
    /// False when the seed is outside `area`.
    @discardableResult
    public static func fill(_ s: inout Surface, area: PixelRect, seed: (x: Int32, y: Int32), tolerance: Float, contiguous: Bool,
                            antiAlias: Bool, color: SIMD4<Float>, opacity: Float, selection: Surface? = nil,
                            lockTransparency: Bool = false) -> Bool {
        fill(&s, area: area, seed: seed, tolerance: tolerance, contiguous: contiguous, antiAlias: antiAlias, opacity: opacity,
             selection: selection, lockTransparency: lockTransparency) { _, _ in color }
    }

    /// Like `fill(color:)` but the colour comes from `source(x, y)` — e.g. a pattern sampled at the
    /// canvas position (photocraft `bucket_fill_src`).
    @discardableResult
    public static func fill(_ s: inout Surface, area: PixelRect, seed: (x: Int32, y: Int32), tolerance: Float, contiguous: Bool,
                            antiAlias: Bool, opacity: Float, selection: Surface? = nil, lockTransparency: Bool = false,
                            source: (Int32, Int32) -> SIMD4<Float>) -> Bool {
        if !area.contains(x: seed.x, y: seed.y) { return false }
        let img = Selection.rgba8Image(s, area: area)
        guard let region = Selection.wandRegion(img, area: area, seed: seed, tolerance: tolerance, contiguous: contiguous, antiAlias: antiAlias)
        else { return false }
        fill(&s, region: region, opacity: opacity, selection: selection, lockTransparency: lockTransparency, source: source)
        return true
    }

    /// Paints a bucket region sampled before the edit, so its boundary can come from the visible
    /// composite while only `s` receives the colour or pattern; the selection still clips it
    /// (photocraft `bucket_fill_region_src`).
    public static func fill(_ s: inout Surface, region: SelectionRegion, opacity: Float, selection: Surface? = nil, lockTransparency: Bool = false,
                            source: (Int32, Int32) -> SIMD4<Float>) {
        let b = region.bbox
        if b.isEmpty { return }
        let bw = b.width
        let mask = region.mask
        if mask.count < bw * b.height { return }
        compositeArea(&s, b, .normal, lockTransparency, selection, coverage: { x, y, sel in
            Float(mask[Int(y - b.y0) * bw + Int(x - b.x0)]) / 255 * opacity * sel
        }, color: source)
    }

    /// Composites `color(x, y)` over `area` with per-pixel coverage, tile by tile; tiles with zero
    /// coverage are left untouched (photocraft `composite_area`). `coverage` receives the
    /// selection's channel 0 at the pixel (1 without one).
    static func compositeArea(_ s: inout Surface, _ area: PixelRect, _ mode: BlendMode, _ lock: Bool, _ selection: Surface?,
                              coverage: (Int32, Int32, Float) -> Float, color: (Int32, Int32) -> SIMD4<Float>) {
        let fmt = s.format
        let n = fmt.channels
        let tiles = area.tiles.map { $0.rect.intersect(area) }.filter { !$0.isEmpty }
        let src = s
        let ctx = FilterContext(bounds: area, format: fmt)
        func work(_ r: PixelRect) -> [Float]? {
            let w = r.width
            let sel = selection.map { ($0.channels, $0.readRegion(r)) }
            var region: [Float] = []
            var any = false
            for y in r.y0..<r.y1 {
                for x in r.x0..<r.x1 {
                    let i = Int(y - r.y0) * w + Int(x - r.x0)
                    let sv: Float = sel.map { sc, v in v[i * sc] } ?? 1
                    let k = coverage(x, y, sv)
                    if k <= 0 { continue }
                    if !any {
                        region = src.readRegion(r)
                        any = true
                    }
                    region.withUnsafeMutableBufferPointer { rb in
                        let px = UnsafeMutableBufferPointer(rebasing: rb[(i * n)..<(i * n + n)])
                        let d = ctx.rgba(UnsafeBufferPointer(px))
                        var o = Blend.composite(mode, backdrop: d, source: color(x, y), opacity: k)
                        if lock { o.w = d.w }
                        ctx.setRGBA(px, o)
                    }
                }
            }
            return any ? region : nil
        }
        var done = [[Float]?](repeating: nil, count: tiles.count)
        done.withUnsafeMutableBufferPointer { db in
            let d = UnsafeSendable(db)
            parallelFor(tiles.count) { t in d.value[t] = work(tiles[t]) }
        }
        for (r, region) in zip(tiles, done) {
            if let region { s.writeRegion(r, region) }
        }
    }
}
