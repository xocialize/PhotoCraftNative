// Port of photocraft-algo (crates/algo/src/segment/mod.rs: Rng, scale_for, subsample, data_costs, components, keep_seeded, clean_mask, antialias_u8, finish_region, refine_band), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Shared machinery of the smart selections (Object Selection, Select Subject, Select Sky, Focus
// Area): working-resolution scale, colour-model data costs, connected components and mask
// cleaning, and `finishRegion`, which turns a working-resolution labelling into a full-resolution
// region by re-cutting a band around the upsampled boundary tile by tile (graph cut with the
// colour models, in parallel) and anti-aliasing it. The image types, samplers, grid cut and
// max-flow live in Selection/QuickSelection.swift and Selection/MaxFlow.swift.

import Foundation
import PCFoundation

extension SegmentKit {
    /// Deterministic xorshift64 (photocraft `segment::Rng`).
    struct Rng {
        var s: UInt64
        init(_ seed: UInt64) { s = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
        mutating func nextU64() -> UInt64 {
            var x = s
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            s = x
            return x
        }
        /// Uniform in [0, 1).
        mutating func f32() -> Float { Float(nextU64() >> 40) / Float(1 << 24) }
        /// Standard normal (Box–Muller).
        mutating func normal() -> Float {
            let u = Float.maximum(f32(), 1e-7), v = f32()
            return (-2 * logf(u)).squareRoot() * cosf(PCAMath.tau * v)
        }
    }
}

/// Smart selections (photocraft `segment`).
public enum Segment {
    /// Integer working-resolution step so that `area` holds at most about `maxPx` pixels.
    public static func scaleFor(_ area: PixelRect, maxPx: Int) -> Int {
        let n = Double(area.width) * Double(area.height)
        return max(Int((n / Double(max(maxPx, 1))).squareRoot().rounded(.up)), 1)
    }

    /// Every k-th element so that at most `max` remain.
    public static func subsample<T>(_ v: [T], max m: Int) -> [T] {
        if v.count <= m { return v }
        let k = (v.count + m - 1) / m
        return Swift.stride(from: 0, to: v.count, by: k).map { v[$0] }
    }

    /// Data costs (−ln p(z|fg), −ln p(z|bg)) for every pixel.
    public static func dataCosts(_ img: SegmentRGBImage, fg: GMM, bg: GMM, on backend: Backend = .cpu) throws -> ([Float], [Float]) {
        if try Selection.useGPU(backend, img.px.count) { return try SegmentKit.GPU.dataCosts(img, fg, bg) }
        var cf = [Float](repeating: 0, count: img.px.count), cb = cf
        cf.withUnsafeMutableBufferPointer { fb in
            cb.withUnsafeMutableBufferPointer { bb in
                let f = UnsafeSendable(fb), b = UnsafeSendable(bb)
                parallelChunks(img.px.count, minChunk: 2048) { r in
                    for i in r { f.value[i] = fg.negLog(img.px[i]); b.value[i] = bg.negLog(img.px[i]) }
                }
            }
        }
        return (cf, cb)
    }

    /// Labels the 8-connected components of `mask`: (labels, 0 = background; sizes by label).
    public static func components(_ mask: [Bool], w: Int, h: Int) -> ([UInt32], [Int]) {
        var lab = [UInt32](repeating: 0, count: w * h)
        var sizes = [0]
        var stack: [Int] = []
        for s in 0..<(w * h) where mask[s] && lab[s] == 0 {
            let l = UInt32(sizes.count)
            sizes.append(0)
            lab[s] = l
            stack.append(s)
            while let i = stack.popLast() {
                sizes[Int(l)] += 1
                let x = i % w, y = i / w
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                        let j = ny * w + nx
                        if mask[j] && lab[j] == 0 { lab[j] = l; stack.append(j) }
                    }
                }
            }
        }
        return (lab, sizes)
    }

    /// Keeps the connected components of `mask` that contain a `seed` pixel.
    public static func keepSeeded(_ mask: [Bool], seeds: [Bool], w: Int, h: Int) -> [Bool] {
        let (lab, sizes) = components(mask, w: w, h: h)
        var keep = [Bool](repeating: false, count: sizes.count)
        for (l, s) in zip(lab, seeds) where s && l != 0 { keep[Int(l)] = true }
        return lab.map { keep[Int($0)] && $0 != 0 }
    }

    /// Keeps components at least `frac` of the largest one and fills holes (4-connected background
    /// areas not touching the border) smaller than `holeFrac` of the kept area.
    public static func cleanMask(_ mask: [Bool], w: Int, h: Int, frac: Float, holeFrac: Float) -> [Bool] {
        let (lab, sizes) = components(mask, w: w, h: h)
        let largest = sizes.dropFirst().max() ?? 0
        if largest == 0 { return [Bool](repeating: false, count: w * h) }
        let minSize = PCAMath.usize((Float(largest) * frac).rounded(.up))
        var out = lab.map { $0 != 0 && sizes[Int($0)] >= minSize }
        let area = out.filter { $0 }.count
        let maxHole = PCAMath.usize(Float(area) * holeFrac)
        let (hl, hs) = SegmentKit.components4(out.map { !$0 }, w, h)
        var touches = [Bool](repeating: false, count: hs.count)
        for x in 0..<w { touches[Int(hl[x])] = true; touches[Int(hl[(h - 1) * w + x])] = true }
        for y in 0..<h { touches[Int(hl[y * w])] = true; touches[Int(hl[y * w + w - 1])] = true }
        for i in 0..<out.count where hl[i] != 0 && !touches[Int(hl[i])] && hs[Int(hl[i])] <= maxHole { out[i] = true }
        return out
    }

    /// Softens a hard 0/255 mask's edges: edge pixels blend with their 3×3 neighbourhood (the
    /// magic wand's anti-aliasing rule).
    public static func antialiasU8(_ mask: inout [UInt8], w: Int, h: Int) {
        let src = mask
        mask.withUnsafeMutableBufferPointer { mb in
            let m = UnsafeSendable(mb)
            src.withUnsafeBufferPointer { s in
                parallelChunks(h, minChunk: 16) { rows in
                    for y in rows {
                        for x in 0..<w {
                            let v = s[y * w + x]
                            var sum: UInt32 = 0
                            var edge = false
                            for dy in -1...1 {
                                for dx in -1...1 {
                                    let nx = x + dx, ny = y + dy
                                    let n = nx < 0 || ny < 0 || nx >= w || ny >= h ? v : s[ny * w + nx]
                                    if n != v { edge = true }
                                    sum += UInt32(n)
                                }
                            }
                            if edge {
                                let avg = Float(sum) / (9 * 255)
                                let f: Float = v > 127 ? 0.5 + 0.5 * avg : 0.5 * avg
                                m.value[y * w + x] = SelectionKit.u8Cast((f * 255).rounded())
                            }
                        }
                    }
                }
            }
        }
    }

    /// Turns a working-resolution labelling over `window` (sampled with `step`) into a
    /// full-resolution region. With step > 1 the boundary is re-cut at full resolution in a band
    /// about `step` pixels wide around the upsampled boundary (with the colour models), tile by
    /// tile. The result is anti-aliased by one pixel.
    public static func finishRegion(_ sampler: any SegmentSampler, window: PixelRect, step: Int, low: [Bool], lw: Int, lh: Int,
                                    models: (GMM, GMM)?) -> SelectionRegion? {
        let w = window.width, h = window.height
        var mask = [UInt8](repeating: 0, count: w * h)
        if step <= 1 {
            for i in 0..<min(mask.count, low.count) { mask[i] = low[i] ? 255 : 0 }
        } else {
            // Band blocks: working pixels with a differently labelled pixel within one block.
            var band = [Bool](repeating: false, count: lw * lh)
            for y in 0..<lh {
                for x in 0..<lw {
                    let v = low[y * lw + x]
                    outer: for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            if nx >= 0 && ny >= 0 && nx < lw && ny < lh && low[ny * lw + nx] != v { band[y * lw + x] = true; break outer }
                        }
                    }
                }
            }
            mask.withUnsafeMutableBufferPointer { mb in
                let m = UnsafeSendable(mb)
                parallelChunks(h, minChunk: 16) { rows in
                    for y in rows {
                        let ly = min(y / step, lh - 1)
                        for x in 0..<w { m.value[y * w + x] = low[ly * lw + min(x / step, lw - 1)] ? 255 : 0 }
                    }
                }
            }
            if let (fg, bg) = models { SegmentKit.refineBand(sampler, window, step, low, band, lw, lh, fg, bg, &mask) }
        }
        antialiasU8(&mask, w: w, h: h)
        return QuickSelection.trimRegion(SelectionRegion(bbox: window, mask: mask))
    }
}

extension SegmentKit {
    /// 4-connected components (photocraft `components4`).
    static func components4(_ mask: [Bool], _ w: Int, _ h: Int) -> ([UInt32], [Int]) {
        var lab = [UInt32](repeating: 0, count: w * h)
        var sizes = [0]
        var stack: [Int] = []
        for s in 0..<(w * h) where mask[s] && lab[s] == 0 {
            let l = UInt32(sizes.count)
            sizes.append(0)
            lab[s] = l
            stack.append(s)
            while let i = stack.popLast() {
                sizes[Int(l)] += 1
                let x = i % w, y = i / w
                for j in [x > 0 ? i - 1 : -1, x + 1 < w ? i + 1 : -1, y > 0 ? i - w : -1, y + 1 < h ? i + w : -1] where j >= 0 {
                    if mask[j] && lab[j] == 0 { lab[j] = l; stack.append(j) }
                }
            }
        }
        return (lab, sizes)
    }

    /// Full-resolution graph cut restricted to the band blocks (photocraft `refine_band`).
    static func refineBand(_ sampler: any SegmentSampler, _ window: PixelRect, _ step: Int, _ low: [Bool], _ band: [Bool], _ lw: Int, _ lh: Int,
                           _ fg: GMM, _ bg: GMM, _ mask: inout [UInt8]) {
        let t: Int32 = 192, halo: Int32 = 12
        let w = window.width
        func block(_ x: Int32, _ y: Int32) -> Int { min(Int(y - window.y0) / step, lh - 1) * lw + min(Int(x - window.x0) / step, lw - 1) }
        var tiles: [PixelRect] = []
        var ty = window.y0
        while ty < window.y1 {
            var tx = window.x0
            while tx < window.x1 {
                let tr = PixelRect(x0: tx, y0: ty, x1: min(tx + t, window.x1), y1: min(ty + t, window.y1))
                let bx0 = Int(tr.x0 - window.x0) / step, by0 = Int(tr.y0 - window.y0) / step
                let bx1 = min(Int(tr.x1 - 1 - window.x0) / step, lw - 1), by1 = min(Int(tr.y1 - 1 - window.y0) / step, lh - 1)
                if (by0...by1).contains(where: { by in (bx0...bx1).contains { bx in band[by * lw + bx] } }) { tiles.append(tr) }
                tx += t
            }
            ty += t
        }
        var results = [[Bool]](repeating: [], count: tiles.count)
        results.withUnsafeMutableBufferPointer { rb in
            let res = UnsafeSendable(rb)
            parallelFor(tiles.count) { k in
                let tile = tiles[k]
                let r = tile.outset(by: halo).intersect(window)
                let img = sampler.rgb(r)
                let rw = r.width, rh = r.height
                var fixed = [UInt8](repeating: QuickSelection.free, count: rw * rh)
                var cfg = [Float](repeating: 0, count: rw * rh), cbg = cfg
                for yy in 0..<rh {
                    for xx in 0..<rw {
                        let i = yy * rw + xx
                        let b = block(r.x0 + Int32(xx), r.y0 + Int32(yy))
                        let lab = low[b]
                        if !band[b] { fixed[i] = lab ? QuickSelection.hardFG : QuickSelection.hardBG; continue }
                        let p = img.px[i]
                        // Colour likelihoods plus a weak prior towards the working-resolution label.
                        cfg[i] = fg.negLog(p) + (lab ? 0 : 0.4)
                        cbg[i] = bg.negLog(p) + (lab ? 0.4 : 0)
                    }
                }
                let beta = QuickSelection.contrastBeta(img)
                let cut = QuickSelection.gridCut(img, costFG: cfg, costBG: cbg, fixed: fixed, gamma: 50, beta: beta)
                let cw = tile.width, ch = tile.height
                var core = [Bool]()
                core.reserveCapacity(cw * ch)
                for yy in 0..<ch {
                    let sy = Int(tile.y0 - r.y0) + yy, sx = Int(tile.x0 - r.x0)
                    core.append(contentsOf: cut[(sy * rw + sx)..<(sy * rw + sx + cw)])
                }
                res.value[k] = core
            }
        }
        for (tile, core) in zip(tiles, results) {
            let cw = tile.width
            for yy in 0..<tile.height {
                let o = Int(tile.y0 - window.y0) * w + yy * w + Int(tile.x0 - window.x0)
                for x in 0..<cw { mask[o + x] = core[yy * cw + x] ? 255 : 0 }
            }
        }
    }
}
