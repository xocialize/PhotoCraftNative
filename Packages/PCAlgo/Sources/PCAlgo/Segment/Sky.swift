// Port of photocraft-algo (crates/algo/src/segment/sky.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Select › Sky, classical: at a working resolution every pixel gets a sky likelihood (a colour
// prior — blue and bright, bright and unsaturated, or a bright warm glow — times a smoothness
// term); sky grows from likely-sky seeds in the top rows through 4-connected neighbours that stay
// likely and change gradually; sky seen through gaps is added when it fits a GMM of the grown sky;
// small holes are filled. The binary mask is upsampled and refined at full resolution with a
// guided filter on the luminance, tile by tile and only where it is mixed, for soft foliage edges.

import Foundation
import PCFoundation

/// Select Sky (photocraft `segment::sky`).
public enum SelectSky {
    /// Working-resolution budget (pixels).
    public static let workPx = 160_000

    /// Sky selection options.
    public struct Params: Sendable, Hashable {
        /// 0–100: higher is stricter (fewer, more certain sky pixels).
        public var threshold: Float = 50
        /// 0–100: edge softness of the refined mask.
        public var softness: Float = 50
        public init(threshold: Float = 50, softness: Float = 50) { self.threshold = threshold; self.softness = softness }
    }

    @inline(__always)
    static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = clampf((x - e0) / (e1 - e0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    static func luma(_ p: SIMD3<Float>) -> Float { 0.299 * p.x + 0.587 * p.y + 0.114 * p.z }

    /// Colour prior: how sky-like a colour is on its own (0–1).
    public static func colourPrior(_ p: SIMD3<Float>) -> Float {
        let (r, g, b) = (p.x, p.y, p.z)
        let y = luma(p)
        let mx = Float.maximum(Float.maximum(r, g), b), mn = Float.minimum(Float.minimum(r, g), b)
        let sat: Float = mx > 1e-4 ? (mx - mn) / mx : 0
        // Blue sky: blue clearly above red and not far below green (excludes foliage).
        let blue = smooth(0.02, 0.12, b - r) * smooth(-0.12, 0, b - g) * smooth(0.18, 0.4, y)
        // Overcast / clouds / haze: bright and nearly neutral.
        let white = smooth(0.5, 0.75, y) * (1 - smooth(0.12, 0.3, sat))
        // Sunset glow: bright and warm, kept weaker.
        let warm = 0.6 * smooth(0.55, 0.8, y) * smooth(0, 0.1, r - b) * (1 - smooth(0.05, 0.25, g - b - 0.2))
        return Float.maximum(Float.maximum(blue, white), warm)
    }

    /// Per-pixel sky likelihood of a working-resolution image (colour prior × smoothness).
    public static func likelihood(_ img: SegmentRGBImage) -> [Float] {
        let w = img.w, h = img.h
        let y = img.px.map(luma)
        func at(_ x: Int, _ yy: Int) -> Float { y[min(max(yy, 0), h - 1) * w + min(max(x, 0), w - 1)] }
        var grad = [Float](repeating: 0, count: w * h)
        for yy in 0..<h {
            for x in 0..<w {
                let gx = (at(x + 1, yy - 1) + 2 * at(x + 1, yy) + at(x + 1, yy + 1)) - (at(x - 1, yy - 1) + 2 * at(x - 1, yy) + at(x - 1, yy + 1))
                let gy = (at(x - 1, yy + 1) + 2 * at(x, yy + 1) + at(x + 1, yy + 1)) - (at(x - 1, yy - 1) + 2 * at(x, yy - 1) + at(x + 1, yy - 1))
                grad[yy * w + x] = (gx * gx + gy * gy).squareRoot() / 8
            }
        }
        let tex = Matting.boxMean(grad, w: w, h: h, r: 2)
        return zip(img.px, tex).map { colourPrior($0) * (1 - smooth(0.015, 0.07, $1)) }
    }

    /// Binary sky mask at working resolution (nil when no sky touches the top of the image).
    public static func skyMaskLow(_ img: SegmentRGBImage, threshold: Float) -> [Bool]? {
        let w = img.w, h = img.h
        if w < 2 || h < 2 { return nil }
        let like = likelihood(img)
        let t = 0.12 + 0.6 * (clampf(threshold, 0, 100) / 100)
        // Seeds: likely sky in the top rows.
        let top = max(h / 40, 1)
        var mask = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for i in 0..<(top * w) where like[i] > t { mask[i] = true; stack.append(i) }
        if stack.count * 20 < top * w { return nil }   // under 5 % of the top edge looks like sky
        // Region growing with a gradual-change constraint.
        let maxStep: Float = 0.12
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for j in [x > 0 ? i - 1 : -1, x + 1 < w ? i + 1 : -1, y > 0 ? i - w : -1, y + 1 < h ? i + w : -1] where j >= 0 {
                if mask[j] || like[j] <= t { continue }
                let a = img.px[i], b = img.px[j]
                let d = ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
                if d < maxStep { mask[j] = true; stack.append(j) }
            }
        }
        // Sky seen through gaps: likely-sky pixels that fit the grown sky's colours.
        let samples = zip(img.px, mask).filter { $0.1 }.map { $0.0 }
        if samples.count >= 16, let g = GMM.fit(Segment.subsample(samples, max: 4000), k: 3, reg: 1e-4) {
            let nl = Segment.subsample(samples, max: 2000).map { g.negLog($0) }.sorted { SelectionKit.totalLess($0, $1) }
            let cut = nl[min(nl.count * 95 / 100, nl.count - 1)]
            for i in 0..<mask.count where !mask[i] && like[i] > t + 0.1 && g.negLog(img.px[i]) <= cut { mask[i] = true }
        }
        let cleaned = Segment.cleanMask(mask, w: w, h: h, frac: 0.002, holeFrac: 0.01)
        return cleaned.contains(true) ? cleaned : nil
    }

    /// Selects the sky over `canvas`; nil if no sky was found.
    public static func select(_ sampler: any SegmentSampler, canvas: PixelRect, _ p: Params = Params()) -> SelectionRegion? {
        if canvas.width < 4 || canvas.height < 4 { return nil }
        let step = Segment.scaleFor(canvas, maxPx: workPx)
        let img = sampler.rgbScaled(canvas, step: step)
        let lw = img.w, lh = img.h
        guard let low = skyMaskLow(img, threshold: p.threshold) else { return nil }
        let lowf = low.map { $0 ? Float(1) : 0 }
        let soft = clampf(p.softness, 0, 100) / 100
        let r = max(SelectionKit.usizeCast((Float(step) * (1 + 2 * soft)).rounded(.up)), 3)
        let eps: Float = 1e-4 + 4e-3 * soft
        // Contrast after filtering: soft 0 → narrow ramp, 1 → the filter output as is.
        let k: Float = 0.08 + 0.42 * soft
        let w = canvas.width, h = canvas.height
        func coarse(_ x: Int32, _ y: Int32) -> Float {
            // Bilinear upsample of the working mask (pixel centres).
            let fx = (Float(x - canvas.x0) + 0.5) / Float(step) - 0.5, fy = (Float(y - canvas.y0) + 0.5) / Float(step) - 0.5
            let x0 = fx.rounded(.down), y0 = fy.rounded(.down)
            let ax = fx - x0, ay = fy - y0
            func g(_ xx: Float, _ yy: Float) -> Float {
                lowf[SelectionKit.usizeCast(clampf(yy, 0, Float(lh) - 1)) * lw + SelectionKit.usizeCast(clampf(xx, 0, Float(lw) - 1))]
            }
            let top = g(x0, y0) * (1 - ax) + g(x0 + 1, y0) * ax
            let bot = g(x0, y0 + 1) * (1 - ax) + g(x0 + 1, y0 + 1) * ax
            return top * (1 - ay) + bot * ay
        }
        let tiles = SegmentKit.tiles(canvas, 256)
        let ri = Int32(r)
        var parts = [[UInt8]](repeating: [], count: tiles.count)
        parts.withUnsafeMutableBufferPointer { pb in
            let pp = UnsafeSendable(pb)
            parallelFor(tiles.count) { kk in
                let t = tiles[kk]
                let win = t.outset(by: ri).intersect(canvas)
                let ww = win.width, wh = win.height
                let pm: [Float] = (0..<(ww * wh)).map { coarse(win.x0 + Int32($0 % ww), win.y0 + Int32($0 / ww)) }
                let lo = pm.reduce(Float.greatestFiniteMagnitude) { Float.minimum($0, $1) }
                let hi = pm.reduce(-Float.greatestFiniteMagnitude) { Float.maximum($0, $1) }
                func crop(_ v: [Float]) -> [UInt8] {
                    var o = [UInt8]()
                    o.reserveCapacity(t.area)
                    for y in t.y0..<t.y1 {
                        for x in t.x0..<t.x1 {
                            let q = v[Int(y - win.y0) * ww + Int(x - win.x0)]
                            o.append(SelectionKit.u8Cast((smooth(0.5 - k, 0.5 + k, q) * 255).rounded()))
                        }
                    }
                    return o
                }
                if hi <= 0 || lo >= 1 {
                    pp.value[kk] = [UInt8](repeating: lo >= 1 ? 255 : 0, count: t.area)
                    return
                }
                let guide = sampler.rgb(win).px.map(luma)
                pp.value[kk] = crop(Matting.guidedFilterGray(guide, pm, w: ww, h: wh, r: r, eps: eps))
            }
        }
        var mask = [UInt8](repeating: 0, count: w * h)
        for (t, v) in zip(tiles, parts) {
            let tw = t.width
            for (row, y) in (t.y0..<t.y1).enumerated() {
                let o = Int(y - canvas.y0) * w + Int(t.x0 - canvas.x0)
                mask.replaceSubrange(o..<(o + tw), with: v[(row * tw)..<(row * tw + tw)])
            }
        }
        return QuickSelection.trimRegion(SelectionRegion(bbox: canvas, mask: mask))
    }
}
