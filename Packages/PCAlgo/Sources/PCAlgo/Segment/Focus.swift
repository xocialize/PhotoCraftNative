// Port of photocraft-algo (crates/algo/src/segment/focus.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Focus Area (heuristic): sharpness as local Laplacian energy (Nayar & Nakagawa, PAMI 1994) on a
// working copy, normalised by its 99th percentile; `noise` subtracts a noise floor; `range`
// (Photoshop's In-Focus Range) lowers the threshold as it grows. The thresholded map is smoothed
// with a colour guided filter so it follows object edges, cleaned, and upsampled with a soft edge.
// Metal: the focus measure (Laplacian and box mean, Shaders/Segment.metal).

import Foundation
import PCFoundation

/// Focus Area (photocraft `segment::focus`).
public enum FocusArea {
    /// Working-resolution budget (pixels).
    public static let workPx = 1_000_000

    /// The Laplacian energy |2c − l − r| + |2c − u − d| of the luma, edges clamped.
    static func laplacian(_ img: SegmentRGBImage) -> [Float] {
        let w = img.w, h = img.h
        let y = img.px.map { 0.299 * $0.x + 0.587 * $0.y + 0.114 * $0.z }
        var lap = [Float](repeating: 0, count: w * h)
        lap.withUnsafeMutableBufferPointer { lb in
            let l = UnsafeSendable(lb)
            parallelChunks(h, minChunk: 16) { rows in
                for yy in rows {
                    for x in 0..<w {
                        let c = y[yy * w + x]
                        l.value[yy * w + x] = abs(2 * c - y[yy * w + (x > 0 ? x - 1 : 0)] - y[yy * w + min(x + 1, w - 1)])
                            + abs(2 * c - y[(yy > 0 ? yy - 1 : 0) * w + x] - y[min(yy + 1, h - 1) * w + x])
                    }
                }
            }
        }
        return lap
    }

    /// The local Laplacian energy (box mean of radius max(min(w, h)/60, 3)) — the focus measure.
    public static func energy(_ img: SegmentRGBImage, on backend: Backend = .cpu) throws -> [Float] {
        let r = max(min(img.w, img.h) / 60, 3)
        if try Selection.useGPU(backend, img.px.count) { return try SegmentKit.GPU.focusEnergy(img, r: r) }
        return Matting.boxMean(laplacian(img), w: img.w, h: img.h, r: r)
    }

    /// Per-pixel normalised sharpness (0…1) of `img`.
    public static func sharpness(_ img: SegmentRGBImage, noise: Float, on backend: Backend = .cpu) throws -> [Float] {
        let e = try energy(img, on: backend)
        if e.isEmpty { return [] }
        let k = min(PCAMath.usize(Float(e.count) * 0.99), e.count - 1)
        let p99 = e.sorted { SelectionKit.totalLess($0, $1) }[k]
        let floor = clampf(noise, 0, 1) * 0.5
        return e.map { Float.maximum(Float.minimum($0 / Float.maximum(p99, 1e-6), 1) - floor, 0) / Float.maximum(1 - floor, 1e-3) }
    }

    /// Focus Area selection over `canvas`.
    public static func select(_ sampler: any SegmentSampler, canvas: PixelRect, range: Float, noise: Float) -> SelectionRegion? {
        if canvas.width < 4 || canvas.height < 4 { return nil }
        let step = Segment.scaleFor(canvas, maxPx: workPx)
        let img = sampler.rgbScaled(canvas, step: step)
        let w = img.w, h = img.h
        guard let s = try? sharpness(img, noise: noise) else { return nil }
        let rc = 1 - clampf(range, 0, 1)
        let t = 0.05 + 0.9 * (rc * rc)
        let bin = s.map { $0 >= t ? Float(1) : 0 }
        let r = max(min(w, h) / 50, 2)
        guard let sm = try? Matting.guidedFilterColor(img, bin, r: r, eps: 1e-2) else { return nil }
        let mask = Segment.cleanMask(sm.map { $0 >= 0.5 }, w: w, h: h, frac: 0.05, holeFrac: 0.02)
        if !mask.contains(true) { return nil }
        // Soft upsampling: bilinear field, steepened to about a working pixel of transition.
        let field = zip(mask, sm).map { m, v in m ? clampf(v, 0.5, 1) : clampf(v, 0, 0.5) }
        let fw = canvas.width, fh = canvas.height
        let st = Float(step)
        var out = [UInt8](repeating: 0, count: fw * fh)
        out.withUnsafeMutableBufferPointer { ob in
            let o = UnsafeSendable(ob)
            parallelChunks(fh, minChunk: 16) { rows in
                for yy in rows {
                    let fy = clampf((Float(yy) + 0.5) / st - 0.5, 0, Float(h - 1))
                    let y0 = Int(fy.rounded(.down)), ty = fy - fy.rounded(.towardZero)
                    let y1 = min(y0 + 1, h - 1)
                    for xx in 0..<fw {
                        let fx = clampf((Float(xx) + 0.5) / st - 0.5, 0, Float(w - 1))
                        let x0 = Int(fx.rounded(.down)), tx = fx - fx.rounded(.towardZero)
                        let x1 = min(x0 + 1, w - 1)
                        let top = field[y0 * w + x0] * (1 - tx) + field[y0 * w + x1] * tx
                        let bot = field[y1 * w + x0] * (1 - tx) + field[y1 * w + x1] * tx
                        let v = top * (1 - ty) + bot * ty
                        o.value[yy * fw + xx] = SelectionKit.u8Cast((clampf((v - 0.5) * 3 + 0.5, 0, 1) * 255).rounded())
                    }
                }
            }
        }
        return QuickSelection.trimRegion(SelectionRegion(bbox: canvas, mask: out))
    }
}
