// Port of photocraft-algo (crates/algo/src/segment/slic.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// SLIC superpixels (Achanta et al., PAMI 2012): k-means in CIELAB + xy restricted to a 2S×2S window
// around each centre, D = d_lab² + (d_xy/S)² m², centres seeded on a grid and moved to the lowest
// gradient of their 3×3 neighbourhood, then connectivity enforcement (small fragments join a
// neighbour). Metal: the assignment step (Shaders/Segment.metal) — each pixel takes the
// nearest centre whose window covers it, ties to the lowest index exactly as the CPU's
// centre-by-centre sweep does, so the labelling is identical; the centre update stays on the CPU.

import Foundation
import PCFoundation

/// A superpixel labelling (photocraft `Superpixels`).
public struct Superpixels: Sendable, Equatable {
    public var w: Int
    public var h: Int
    /// Label per pixel, 0..<count.
    public var labels: [UInt32]
    public var count: Int
    /// Grid interval S used.
    public var step: Float
}

/// SLIC superpixels (photocraft `segment::slic`).
public enum SLIC {
    /// sRGB (0…1) to CIELAB (D65), L in 0…100.
    public static func rgbToLab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.x), g = lin(c.y), b = lin(c.z)
        let x = (0.412_456_4 * r + 0.357_576_1 * g + 0.180_437_5 * b) / 0.950_47
        let y = 0.212_672_9 * r + 0.715_152_2 * g + 0.072_175 * b
        let z = (0.019_333_9 * r + 0.119_192 * g + 0.950_304_1 * b) / 1.088_83
        func f(_ t: Float) -> Float { t > 0.008_856 ? cbrtf(t) : 7.787 * t + 16.0 / 116.0 }
        let fx = f(x), fy = f(y), fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Segments `img` into about `target` superpixels; `compactness` is SLIC's m (10 is typical),
    /// `iters` the k-means iterations (10 in the paper).
    public static func slic(_ img: SegmentRGBImage, target: Int, compactness: Float, iters: Int, on backend: Backend = .cpu) throws -> Superpixels {
        try slicLab(img.px.map(rgbToLab), w: img.w, h: img.h, target: target, compactness: compactness, iters: iters, on: backend)
    }

    /// `slic` on a CIELAB image.
    public static func slicLab(_ lab: [SIMD3<Float>], w: Int, h: Int, target: Int, compactness: Float, iters: Int, on backend: Backend = .cpu) throws -> Superpixels {
        let n = w * h
        if n == 0 { return Superpixels(w: w, h: h, labels: [], count: 0, step: 1) }
        let s = Float.maximum((Float(n) / Float(max(target, 1))).squareRoot(), 1)
        func at(_ x: Int, _ y: Int) -> SIMD3<Float> { lab[min(y, h - 1) * w + min(x, w - 1)] }
        func grad(_ x: Int, _ y: Int) -> Float {
            QuickSelection.d2(at(x > 0 ? x - 1 : 0, y), at(x + 1, y)) + QuickSelection.d2(at(x, y > 0 ? y - 1 : 0), at(x, y + 1))
        }
        // Seed centres: L, a, b, x, y.
        var centers: [[Float]] = []
        var y = s / 2
        while y < Float(h) {
            var x = s / 2
            while x < Float(w) {
                let cx = Int(x), cy = Int(y)
                var bx = cx, by = cy, bg = Float.greatestFiniteMagnitude
                for yy in (cy > 0 ? cy - 1 : 0)...min(cy + 1, h - 1) {
                    for xx in (cx > 0 ? cx - 1 : 0)...min(cx + 1, w - 1) {
                        let g = grad(xx, yy)
                        if g < bg { (bx, by, bg) = (xx, yy, g) }
                    }
                }
                let c = lab[by * w + bx]
                centers.append([c.x, c.y, c.z, Float(bx), Float(by)])
                x += s
            }
            y += s
        }
        var labels = [UInt32](repeating: UInt32.max, count: n)
        var dist = [Float](repeating: Float.greatestFiniteMagnitude, count: n)
        let wxy = (compactness / s) * (compactness / s)
        let r = Int(s.rounded(.up))
        let gpu = try Selection.useGPU(backend, n)
        let gpuLab = gpu ? try SelectionKit.GPU.buffer(lab.map { SIMD4($0, 0) }) : nil
        for _ in 0..<max(iters, 1) {
            if let gpuLab {
                labels = try SegmentKit.GPU.slicAssign(gpuLab, labels, centers, w: w, h: h, r: r, wxy: wxy)
            } else {
                for i in 0..<n { dist[i] = Float.greatestFiniteMagnitude }
                for (k, c) in centers.enumerated() {
                    let cx = Int(c[3].rounded()), cy = Int(c[4].rounded())
                    let cl = SIMD3(c[0], c[1], c[2])
                    for yy in max(cy - r, 0)..<max(min(cy + r + 1, h), max(cy - r, 0)) {
                        for xx in max(cx - r, 0)..<max(min(cx + r + 1, w), max(cx - r, 0)) {
                            let i = yy * w + xx
                            let dc = QuickSelection.d2(lab[i], cl)
                            let dx = Float(xx) - c[3], dy = Float(yy) - c[4]
                            let d = dc + (dx * dx + dy * dy) * wxy
                            if d < dist[i] { dist[i] = d; labels[i] = UInt32(k) }
                        }
                    }
                }
            }
            var sums = [[Double]](repeating: [Double](repeating: 0, count: 6), count: centers.count)
            for (i, l) in labels.enumerated() where l != UInt32.max {
                let p = lab[i]
                sums[Int(l)][0] += Double(p.x); sums[Int(l)][1] += Double(p.y); sums[Int(l)][2] += Double(p.z)
                sums[Int(l)][3] += Double(i % w); sums[Int(l)][4] += Double(i / w); sums[Int(l)][5] += 1
            }
            for k in 0..<centers.count where sums[k][5] > 0 { centers[k] = (0..<5).map { Float(sums[k][$0] / sums[k][5]) } }
        }
        // Unreached pixels (possible at the far edges): the label of the previous pixel.
        for i in 0..<n where labels[i] == UInt32.max { labels[i] = i > 0 ? labels[i - 1] : 0 }
        let (out, count) = enforceConnectivity(labels, w, h, PCAMath.usize(s * s / 4))
        return Superpixels(w: w, h: h, labels: out, count: count, step: s)
    }

    /// Relabels 4-connected components; components smaller than `minSize` merge into the adjacent
    /// component found before them (the SLIC paper's post-processing).
    static func enforceConnectivity(_ labels: [UInt32], _ w: Int, _ h: Int, _ minSize: Int) -> ([UInt32], Int) {
        let n = w * h
        var out = [UInt32](repeating: UInt32.max, count: n)
        var next: UInt32 = 0
        var comp: [Int] = []
        for s in 0..<n where out[s] == UInt32.max {
            // Adjacent already-labelled component (to merge into if this one is small).
            let sx = s % w, sy = s / w
            var adj: UInt32?
            for j in [sx > 0 ? s - 1 : -1, sy > 0 ? s - w : -1] where j >= 0 && out[j] != UInt32.max { adj = out[j] }
            comp.removeAll(keepingCapacity: true)
            comp.append(s)
            out[s] = next
            var k = 0
            while k < comp.count {
                let i = comp[k]
                k += 1
                let x = i % w, y = i / w
                for j in [x > 0 ? i - 1 : -1, x + 1 < w ? i + 1 : -1, y > 0 ? i - w : -1, y + 1 < h ? i + w : -1] where j >= 0 {
                    if out[j] == UInt32.max && labels[j] == labels[s] { out[j] = next; comp.append(j) }
                }
            }
            if let a = adj, comp.count < minSize { for i in comp { out[i] = a } } else { next += 1 }
        }
        return (out, Int(next))
    }
}
