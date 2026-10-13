// Port of photocraft-algo (crates/algo/src/erase.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Magic Eraser: erases a wand region to transparency (or, on a layer with locked transparency, to
// a colour), tile by tile, in the surface's own channels at any depth and in any colour model:
// only the alpha channel changes (or, under a lock, the colour channels move toward the colour).
// Tiles are edited as encoded bytes in parallel and copied back serially.

import Foundation
import PCFoundation

/// Magic Eraser (photocraft `erase`).
public enum MagicEraser {
    /// Erases `region` from `target` at `amount` (0–1, the tool's opacity), weighted by the
    /// selection's coverage. With `lockColor` (native colour channels) the pixels are painted toward
    /// that colour instead and alpha is kept. Returns the damaged rectangle (photocraft `magic_erase`).
    @discardableResult
    public static func erase(_ target: inout Surface, region: SelectionRegion, amount a0: Float, selection: Surface? = nil,
                             lockColor: [Float]? = nil) -> PixelRect {
        let amount = a0.isFinite ? min(max(a0, 0), 1) : 0
        let bbox = region.bbox
        let bw = bbox.width
        if bbox.isEmpty || amount <= 0 || region.mask.count != bw * bbox.height { return .empty }
        let fmt = target.format
        let nc = fmt.mode.colorChannels
        let alpha: Int? = fmt.alpha ? nc : nil
        // Without alpha and without a lock colour there is nothing an eraser can do.
        if alpha == nil && lockColor == nil { return .empty }
        let lock: [Float]? = lockColor.map { c in (0..<nc).map { $0 < c.count ? c[$0] : 0 } }
        let rects = bbox.tiles.map { $0.rect.intersect(bbox) }.filter { !$0.isEmpty }
        let sample = fmt.sample, bpp = fmt.bytesPerPixel, nch = fmt.channels
        let src = target
        let mask = region.mask
        @inline(__always) func cov(_ x: Int32, _ y: Int32) -> UInt8 { mask[Int(y - bbox.y0) * bw + Int(x - bbox.x0)] }
        func work(_ r: PixelRect) -> [UInt8]? {
            let w = r.width
            // Skip tiles the region doesn't touch.
            var touched = false
            outer: for y in r.y0..<r.y1 { for x in r.x0..<r.x1 where cov(x, y) != 0 { touched = true; break outer } }
            if !touched { return nil }
            var bytes = src.readInterleaved(r)
            let sel = selection.map { ($0.channels, $0.readRegion(r)) }
            bytes.withUnsafeMutableBytes { p in
                for y in r.y0..<r.y1 {
                    for x in r.x0..<r.x1 {
                        let c = cov(x, y)
                        if c == 0 { continue }
                        let i = Int(y - r.y0) * w + Int(x - r.x0)
                        let s: Float = sel.map { sc, v in i * sc < v.count ? v[i * sc] : 0 } ?? 1
                        let k = Float(c) / 255 * amount * s
                        if k <= 0 { continue }
                        let base = i * nch
                        if let col = lock {
                            for (ch, t) in col.enumerated() {
                                let v = readSample(UnsafeRawBufferPointer(p), sample, base + ch)
                                writeSample(p, sample, base + ch, v + (t - v) * k)
                            }
                        } else if let a = alpha {
                            let v = readSample(UnsafeRawBufferPointer(p), sample, base + a) * (1 - k)
                            if k >= 1 || v <= 0 {
                                // Fully erased pixels become the empty pixel, so tiles can be pruned.
                                for b in (i * bpp)..<((i + 1) * bpp) { p[b] = 0 }
                            } else {
                                writeSample(p, sample, base + a, v)
                            }
                        }
                    }
                }
            }
            return bytes
        }
        var done = [[UInt8]?](repeating: nil, count: rects.count)
        done.withUnsafeMutableBufferPointer { db in
            let d = UnsafeSendable(db)
            parallelFor(rects.count) { t in d.value[t] = work(rects[t]) }
        }
        var dmg = PixelRect.empty
        for (r, bytes) in zip(rects, done) {
            guard let bytes else { continue }
            target.writeInterleaved(r, bytes)
            dmg = dmg.union(r)
        }
        if lock == nil { target.prune() }
        return dmg
    }
}
