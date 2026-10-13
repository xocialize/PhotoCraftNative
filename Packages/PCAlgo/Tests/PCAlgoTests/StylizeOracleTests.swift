// Port of photocraft-algo (crates/algo/src/tests_mosaic.rs, stylize2/tests.rs, stylize2.rs `extrude_direct`, stylize2/wind.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft keeps its original scalar kernels as test oracles for the optimised paths (Mosaic's
// cell-once traversal, Extrude's swept rasteriser, Wind's streak scatter). The same oracles here
// check the Swift references (Mosaic per cell, Extrude's pruned candidate search, Wind's per-row
// luma search) bit for bit.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum StyOracle {
    /// Bitwise sample equality (NaN payloads included).
    static func sameBits(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
    }

    // MARK: Fixtures

    /// tests_mosaic.rs `image_pattern`: LCG noise with some zero alphas.
    static func imagePattern(_ rect: PixelRect, _ ch: Int) -> FloatImage {
        var seed: UInt32 = 0x72e_1905
        let data: [Float] = (0..<(rect.area * ch)).map { i in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return i % ch == ch - 1 && i % 11 == 0 ? 0 : Float(seed >> 8) / 16_777_215
        }
        return FloatImage(rect: rect, channels: ch, data: data)
    }

    /// stylize2/tests.rs `image`: xorshift samples of five kinds (kind 4: non-finite and HDR).
    static func image(_ rect: PixelRect, _ n: Int, _ kind: Int) -> FloatImage {
        var img = FloatImage(rect: rect, channels: n)
        var s: UInt32 = 0x2545_f491
        for i in 0..<img.data.count {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5
            switch kind {
            case 0: img.data[i] = Float(s % 256) / 255
            case 1: img.data[i] = Float((i / n) % 5) / 4
            case 2: img.data[i] = 0
            case 3: img.data[i] = Float(s % 65536) / 65535
            default: img.data[i] = [Float.nan, .infinity, -.infinity, -0.0, -2, 3.5, 0.5][Int(s % 7)]
            }
        }
        return img
    }

    static let models: [ColorMode] = [.rgb, .grayscale, .cmyk, .lab, .bitmap, .duotone, .indexed, .multichannel]

    static func channels(_ mode: ColorMode, _ alpha: Bool) -> Int { PixelFormat(mode: mode, sample: .f32, alpha: alpha).channels }

    // MARK: Mosaic

    /// tests_mosaic.rs `legacy_mosaic`: the per-pixel traversal with a one-cell cache.
    static func legacyMosaic(_ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext, _ cell: Float) -> [Float] {
        let n = src.channels
        let cs = StylizeKit.i32(StylizeKit.fmax(cell, 1).rounded(.toNearestOrAwayFromZero))
        let b = ctx.bounds
        var res: [Float] = []
        var cache: (Int32, Int32, [Float])?
        for y in out.y0..<out.y1 {
            for x in out.x0..<out.x1 {
                let cx = StylizeKit.divEuclid(x - b.x0, cs), cy = StylizeKit.divEuclid(y - b.y0, cs)
                if cache == nil || cache!.0 != cx || cache!.1 != cy {
                    let r = PixelRect(x0: b.x0 + cx * cs, y0: b.y0 + cy * cs, x1: b.x0 + (cx + 1) * cs, y1: b.y0 + (cy + 1) * cs).intersect(b)
                    var acc = [Float](repeating: 0, count: n)
                    var count: Float = 0
                    if !r.isEmpty {
                        for yy in r.y0..<r.y1 {
                            for xx in r.x0..<r.x1 {
                                let a: Float = ctx.alpha ? src.get(xx, yy, n - 1) : 1
                                for c in 0..<n {
                                    let s = src.get(xx, yy, c)
                                    acc[c] += ctx.alpha && c < n - 1 ? s * a : s
                                }
                                count += 1
                            }
                        }
                    }
                    if count > 0 { for c in 0..<n { acc[c] /= count } }
                    if ctx.alpha {
                        let a = acc[n - 1]
                        for c in 0..<(n - 1) { acc[c] = a > 1e-7 ? acc[c] / a : 0 }
                    }
                    cache = (cx, cy, acc)
                }
                res.append(contentsOf: cache!.2)
            }
        }
        return res
    }

    // MARK: Extrude

    /// stylize2.rs `extrude_direct`: every candidate cell within `k` of the pixel's own cell.
    static func extrudeDirect(_ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext, _ spec: Extrude) -> [Float] {
        let n = src.channels
        let cs = StylizeKit.i32(clampf(spec.size, 2, 255).rounded(.toNearestOrAwayFromZero))
        let b = ctx.bounds
        let (bcx, bcy) = (Float(b.x0 + b.x1) / 2, Float(b.y0 + b.y1) / 2)
        let halfDiag = StylizeKit.fmax(hypotf(Float(b.width), Float(b.height)) / 2, 1)
        let reach = clampf(spec.depth, 0, 255) * 0.25
        var res = src.crop(out).data
        func cellRect(_ gx: Int32, _ gy: Int32) -> PixelRect { PixelRect(x0: b.x0 + gx * cs, y0: b.y0 + gy * cs, x1: b.x0 + (gx + 1) * cs, y1: b.y0 + (gy + 1) * cs) }
        func incomplete(_ r: PixelRect) -> Bool { r.intersect(b) != r }
        // Lazily computed cell infos (a plain per-cell cache; values as computed on demand).
        let kMax = StylizeKit.i32((reach / Float(cs)).rounded(.up)) + 1
        let gxLo = StylizeKit.divEuclid(out.x0 - b.x0, cs) - kMax - 1, gyLo = StylizeKit.divEuclid(out.y0 - b.y0, cs) - kMax - 1
        let gw = Int(StylizeKit.divEuclid(out.x1 - b.x0, cs) + kMax + 2 - gxLo), gh = Int(StylizeKit.divEuclid(out.y1 - b.y0, cs) + kMax + 2 - gyLo)
        var hCache = [Float](repeating: 0, count: gw * gh), colCache = [[Float]](repeating: [], count: gw * gh)
        var have = [Bool](repeating: false, count: gw * gh)
        func info(_ gx: Int32, _ gy: Int32) -> ([Float], Float) {
            let slot = Int(gy - gyLo) * gw + Int(gx - gxLo)
            if have[slot] { return (colCache[slot], hCache[slot]) }
            let r = cellRect(gx, gy).intersect(b)
            var acc = [Float](repeating: 0, count: n)
            var cnt: Float = 0
            let step = max(cs / 8, 1)
            var yy = r.y0
            while yy < r.y1 {
                var xx = r.x0
                while xx < r.x1 {
                    let a: Float = ctx.alpha ? src.get(xx, yy, n - 1) : 1
                    for c in 0..<n {
                        let s = src.get(xx, yy, c)
                        acc[c] += ctx.alpha && c < n - 1 ? s * a : s
                    }
                    cnt += 1
                    xx += step
                }
                yy += step
            }
            if cnt > 0 { for c in 0..<n { acc[c] /= cnt } }
            if ctx.alpha {
                let a = acc[n - 1]
                for c in 0..<(n - 1) { acc[c] = a > 1e-7 ? acc[c] / a : 0 }
            }
            let h = spec.levelBased ? clampf(acc.withUnsafeBufferPointer { ctx.luma($0) }, 0, 1) : hash01(gx, gy, 21, spec.seed)
            have[slot] = true; hCache[slot] = h; colCache[slot] = acc
            return (acc, h)
        }
        let cc = ctx.colorChannels(n), sub = ctx.subtractive
        func shade(_ o: Int, _ col: [Float], _ k: Float) {
            for c in 0..<cc { res[o + c] = clampf(sub ? 1 - (1 - col[c]) * k : col[c] * k, 0, 1) }
            if ctx.alpha { res[o + n - 1] = col[n - 1] }
        }
        let w = out.width
        for i in 0..<out.area {
            let (x, y) = (out.x0 + Int32(i % w), out.y0 + Int32(i / w))
            if !b.contains(x: x, y: y) { continue }
            let o = i * n
            let (fx, fy) = (Float(x) + 0.5, Float(y) + 0.5)
            let (gx, gy) = (StylizeKit.divEuclid(x - b.x0, cs), StylizeKit.divEuclid(y - b.y0, cs))
            switch spec.kind {
            case .pyramids:
                let r = cellRect(gx, gy)
                if spec.maskIncomplete && incomplete(r) { continue }
                let (col, h) = info(gx, gy)
                let (u, v) = (fx - (Float(r.x0) + Float(cs) / 2), fy - (Float(r.y0) + Float(cs) / 2))
                let hgt = h * clampf(spec.depth, 1, 255) / 255 * Float(cs)
                let s = Float(cs) / 2
                let (nx, ny): (Float, Float) = abs(u) >= abs(v) ? (StylizeKit.signum(u) * hgt, 0) : (0, StylizeKit.signum(v) * hgt)
                let norm = (nx * nx + ny * ny + s * s).squareRoot()
                let (lx, ly, lz): (Float, Float, Float) = (-0.5, -0.5, 0.70710677)
                let lambert = StylizeKit.fmax((nx * lx + ny * ly + s * lz) / norm, 0)
                shade(o, col, 0.35 + 0.9 * lambert)
            case .blocks:
                let k = StylizeKit.i32((reach / Float(cs)).rounded(.up)) + 1
                var best: (Float, Int32, Int32, Int)?
                for dy in -k...k {
                    for dx in -k...k {
                        let (cx, cy) = (gx + dx, gy + dy)
                        let r = cellRect(cx, cy)
                        if r.x1 <= b.x0 || r.y1 <= b.y0 || r.x0 >= b.x1 || r.y0 >= b.y1 { continue }
                        if spec.maskIncomplete && incomplete(r) { continue }
                        let h = info(cx, cy).1
                        if let bb = best, bb.0 >= h { continue }
                        let (mx, my) = (Float(r.x0) + Float(cs) / 2, Float(r.y0) + Float(cs) / 2)
                        let off = reach * h / halfDiag
                        let (ox, oy) = ((mx - bcx) * off, (my - bcy) * off)
                        let half = Float(cs) / 2
                        func interval(_ p: Float, _ m: Float, _ o: Float) -> (Float, Float)? {
                            if abs(o) < 1e-6 { return abs(p - m) <= half ? (0, 1) : nil }
                            let (a, bb) = ((p - m - half) / o, (p - m + half) / o)
                            let (lo, hi) = (StylizeKit.fmax(StylizeKit.fmin(a, bb), 0), StylizeKit.fmin(StylizeKit.fmax(a, bb), 1))
                            return lo <= hi ? (lo, hi) : nil
                        }
                        guard let ix = interval(fx, mx, ox), let iy = interval(fy, my, oy) else { continue }
                        let (lo, hi) = (max(ix.0, iy.0), min(ix.1, iy.1))
                        if lo > hi { continue }
                        let face = hi >= 1 ? 0 : ix.1 < iy.1 ? (ox > 0 ? 1 : 2) : oy > 0 ? 3 : 4
                        best = (h, cx, cy, face)
                    }
                }
                guard let (h, cx, cy, face) = best else { continue }
                let r = cellRect(cx, cy)
                let (mx, my) = (Float(r.x0) + Float(cs) / 2, Float(r.y0) + Float(cs) / 2)
                let off = reach * h / halfDiag
                let col = info(cx, cy).0
                if face == 0 {
                    if spec.solidFront {
                        shade(o, col, 1)
                    } else {
                        let sx = min(max(StylizeKit.i32((fx - (mx - bcx) * off).rounded(.down)), r.x0), r.x1 - 1)
                        let sy = min(max(StylizeKit.i32((fy - (my - bcy) * off).rounded(.down)), r.y0), r.y1 - 1)
                        for c in 0..<n { res[o + c] = src.get(sx, sy, c) }
                    }
                } else {
                    shade(o, col, face == 1 ? 0.85 : face == 2 ? 0.55 : face == 3 ? 0.95 : 0.45)
                }
            }
        }
        return res
    }

    // MARK: Wind

    /// stylize2/wind.rs `streaks`: each source's streak scattered once (nil for Stagger).
    static func windStreaks(_ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext, _ wind: Wind) -> [Float]? {
        let n = src.channels
        if wind.method == .stagger || n == 0 || out.isEmpty { return nil }
        let w = out.width
        let lmax = Int32(Wind.reach(wind.method))
        let d: Int32 = wind.fromRight ? -1 : 1
        let start = wind.fromRight ? out.x1 + lmax - 1 : out.x0 - lmax
        let sources = w + Int(lmax)
        var res = src.crop(out).data
        let strength: Float = wind.method == .blast ? 8 : 4
        var tmp = [Float](repeating: 0, count: n)
        func lum(_ x: Int32, _ y: Int32) -> Float {
            for c in 0..<n { tmp[c] = src.get(x, y, c) }
            return tmp.withUnsafeBufferPointer { ctx.luma($0) }
        }
        for y in out.y0..<out.y1 {
            var best = [(Float, Int32)](repeating: (0, lmax + 1), count: w)
            var prev = lum(start - d, y)
            for step in 0..<sources {
                let s = start + d * Int32(step)
                let l = lum(s, y)
                let edge = StylizeKit.fmin(abs(l - prev) * strength, 1)
                prev = l
                if !(edge > 0) { continue }
                let h = hash01(s, y, 44, wind.seed)
                let len = StylizeKit.fmax(h * h * Float(lmax), 1)
                let kmax = min(StylizeKit.i32(len.rounded(.down)), lmax)
                if kmax < 1 { continue }
                for k in 1...kmax {
                    let x = s + d * k
                    if x < out.x0 || x >= out.x1 { continue }
                    let weight = edge * (1 - Float(k) / (len + 1))
                    let hit = best[Int(x - out.x0)]
                    // Sources are visited downwind; equal weights prefer the smallest original k.
                    if weight > hit.0 || (weight == hit.0 && k < hit.1) { best[Int(x - out.x0)] = (weight, k) }
                }
            }
            let row = Int(y - out.y0) * w * n
            for (x, (weight, k)) in best.enumerated() where weight > 0 {
                let sx = out.x0 + Int32(x) - d * k
                for c in 0..<n {
                    let o = row + x * n + c
                    res[o] += (src.get(sx, y, c) - res[o]) * weight
                }
            }
        }
        return res
    }
}

@Suite struct StylizeOracleTests {
    // MARK: tests_mosaic.rs

    @Test func mosaicMatchesLegacyForPartialCellsAndOffsetBounds() {
        for b in [PixelRect(x0: 0, y0: 0, x1: 47, y1: 61), PixelRect(x0: -5, y0: 7, x1: 42, y1: 68)] {
            // photocraft runs channels 1…5 and nine cell sizes; 3 channels and sizes 1 / 80 add nothing
            // the others don't cover (the 4-channel fast path and partial cells are kept).
            for ch in [1, 2, 4, 5] {
                for alpha in [false, true] {
                    for rect in [b, PixelRect(x0: b.x0 + 3, y0: b.y0 + 5, x1: b.x1 - 6, y1: b.y1 - 8)] {
                        let src = StyOracle.imagePattern(rect, ch)
                        let ctx = FilterContext(bounds: b, mode: .rgb, alpha: alpha)
                        let outputs = [b, PixelRect(x0: b.x0 + 4, y0: b.y0 + 2, x1: b.x1 - 3, y1: b.y1 - 4),
                                       PixelRect(x0: b.x0 + 9, y0: b.y0 + 9, x1: b.x0 + 16, y1: b.y0 + 17),
                                       PixelRect(x0: b.x0 - 3, y0: b.y0 - 4, x1: b.x1 + 6, y1: b.y1 + 8),
                                       PixelRect(x0: b.x1 + 2, y0: b.y1 - 3, x1: b.x1 + 12, y1: b.y1 + 5),
                                       PixelRect(x0: b.x0, y0: b.y0, x1: b.x0, y1: b.y1), PixelRect(x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y0)]
                        for output in outputs {
                            for size: Float in [0, 1.5, 2, 7, 13, 50, 180] {
                                let want = StyOracle.legacyMosaic(src, output, ctx, size)
                                let got = Mosaic(cellSize: size).cpu(src, out: output, ctx: ctx).data
                                #expect(StyOracle.sameBits(got, want), "bounds \(b) source \(rect) output \(output) ch \(ch) alpha \(alpha) cell \(size)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func mosaicPreservesDepthColorAlphaAndTileIndependence() throws {
        let b = PixelRect(x0: 13, y0: -7, x1: 92, y1: 54)
        for sample in [SampleType.u8, .u16, .f32] {
            for mode in [ColorMode.grayscale, .rgb, .cmyk, .lab] {
                for alpha in [false, true] where sample != .u16 || mode == .rgb {
                    let fmt = PixelFormat(mode: mode, sample: sample, alpha: alpha)
                    var input = Surface(format: fmt)
                    input.writeRegion(b, StyOracle.imagePattern(b, fmt.channels).data)
                    let src = FloatImage(surface: input, rect: b)
                    let ctx = FilterContext(bounds: b, mode: mode, alpha: alpha)
                    // photocraft runs every cell × tile 17/256 × extent; the debug build takes a
                    // representative subset (a 17 px tile with a 180 px cell reads 379² px per tile).
                    let cases: [(Float, Int, PixelRect?)] = [(6, 17, nil), (13, 17, b), (50, 17, nil), (6, 256, b), (50, 256, b), (180, 256, nil)]
                    for cell: Float in [6, 13, 50, 180] {
                        var expected = Surface(format: fmt)
                        expected.writeRegion(b, StyOracle.legacyMosaic(src, b, ctx, cell))
                        let bytes = expected.readInterleaved(b)
                        for (_, tile, extent) in cases.filter({ $0.0 == cell }) {
                            do {
                                var got = input
                                try FilterEngine.apply(Mosaic(cellSize: cell), to: &got, area: b, bounds: b, extent: extent, on: .cpu, tile: tile)
                                #expect(got.readInterleaved(b) == bytes, "\(sample) \(mode) alpha \(alpha) cell \(cell) tile \(tile) extent \(String(describing: extent))")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func mosaicHandlesZeroChannels() {
        let rect = PixelRect(x0: 0, y0: 0, x1: 3, y1: 3)
        let src = FloatImage(rect: rect, channels: 0)
        for alpha in [false, true] {
            #expect(Mosaic(cellSize: 2).cpu(src, out: rect, ctx: FilterContext(bounds: rect, mode: .rgb, alpha: alpha)).data.isEmpty)
        }
    }

    @Test func mosaicRowReadsPreserveHDRAlphaAndPartialSourceBits() {
        let bounds = PixelRect(x0: -7, y0: 3, x1: 30, y1: 26)
        for rect in [bounds, PixelRect(x0: -3, y0: 7, x1: 23, y1: 21)] {
            var src = StyOracle.imagePattern(rect, 4)
            for i in 0..<rect.area {
                let p = i * 4
                src.data[p] = src.data[p] * 8 - 4
                src.data[p + 1] = i % 3 == 0 ? -0.0 : src.data[p + 1] * 16
                src.data[p + 2] = i % 7 == 0 ? Float.leastNormalMagnitude : -src.data[p + 2]
                src.data[p + 3] = i % 5 == 0 ? 0 : src.data[p + 3]
            }
            for alpha in [false, true] {
                let ctx = FilterContext(bounds: bounds, mode: .rgb, alpha: alpha)
                for cell: Float in [2, 4, 10, 50, 180] {
                    #expect(StyOracle.sameBits(Mosaic(cellSize: cell).cpu(src, out: bounds, ctx: ctx).data, StyOracle.legacyMosaic(src, bounds, ctx, cell)))
                }
            }
        }
    }

    // MARK: stylize2/tests.rs

    /// photocraft `swept_blocks_match_the_pixel_search`: the pruned search equals the full one
    /// in every model, for non-finite inputs too. The two geometries with hundreds to thousands
    /// of oracle candidates per pixel (4 px cells at depth 190, 2 px cells at depth 255) run on a
    /// subset of models, kinds and flags to keep the debug test quick.
    @Test func prunedBlocksMatchThePixelSearch() {
        let bounds = PixelRect(x0: -13, y0: -9, x1: 31, y1: 26)
        let out = PixelRect(x0: -17, y0: -2, x1: 24, y1: 29)
        for mode in StyOracle.models {
            for alpha in [false, true] {
                let n = StyOracle.channels(mode, alpha)
                let ctx = FilterContext(bounds: bounds, mode: mode, alpha: alpha)
                for kind in 0..<5 {
                    let src = StyOracle.image(bounds.outset(by: 20), n, kind)
                    for (size, depth): (Float, Float) in [(2, 0), (2, 255), (3.5, 190), (8, 64), (22, 255), (255, 100)] {
                        let main = [ColorMode.rgb, .grayscale, .cmyk, .lab].contains(mode)
                        // Kinds 0 (8-bit), 1 (flat runs) and 4 (non-finite) in the main models; the
                        // other models share their luma paths with Gray / RGB.
                        if !(main ? [0, 1, 4] : [0, 4]).contains(kind) { continue }
                        var flagSet = main && (size == 8 || size == 22) ? Array(0..<8) : [0, 1, 6, 7]
                        if !main { flagSet = [0, 1, 7] }
                        if size == 3.5 {
                            if ![.rgb, .lab].contains(mode) || kind == 1 { continue }
                            flagSet = [1, 6]
                        } else if size == 2 && depth == 255 {
                            if mode != .rgb || kind == 1 { continue }
                            flagSet = [1, 7]
                        }
                        for flags in flagSet {
                            let spec = Extrude(kind: .blocks, size: size, depth: depth, levelBased: flags & 1 != 0, solidFront: flags & 2 != 0,
                                               maskIncomplete: flags & 4 != 0, seed: 17)
                            #expect(StyOracle.sameBits(spec.cpu(src, out: out, ctx: ctx).data, StyOracle.extrudeDirect(src, out, ctx, spec)),
                                    "\(mode) alpha \(alpha) kind \(kind) size \(size) depth \(depth) flags \(flags)")
                        }
                    }
                }
            }
        }
    }

    @Test func pyramidsMatchThePixelSearch() {
        let bounds = PixelRect(x0: -13, y0: -9, x1: 31, y1: 26)
        let out = PixelRect(x0: -17, y0: -2, x1: 24, y1: 29)
        for mode in StyOracle.models {
            for alpha in [false, true] {
                let ctx = FilterContext(bounds: bounds, mode: mode, alpha: alpha)
                for kind in 0..<5 {
                    let src = StyOracle.image(bounds.outset(by: 20), StyOracle.channels(mode, alpha), kind)
                    for (size, depth): (Float, Float) in [(2, 0), (3.5, 190), (8, 64), (22, 255)] {
                        for flags in [0, 1, 4, 5] {
                            let spec = Extrude(kind: .pyramids, size: size, depth: depth, levelBased: flags & 1 != 0, maskIncomplete: flags & 4 != 0, seed: 17)
                            #expect(StyOracle.sameBits(spec.cpu(src, out: out, ctx: ctx).data, StyOracle.extrudeDirect(src, out, ctx, spec)))
                        }
                    }
                }
            }
        }
    }

    @Test func streakScatterMatchesThePixelSearch() {
        let bounds = PixelRect(x0: -17, y0: -9, x1: 39, y1: 14)
        for mode in StyOracle.models {
            for alpha in [false, true] {
                let ctx = FilterContext(bounds: bounds, mode: mode, alpha: alpha)
                for kind in 0..<5 {
                    let src = StyOracle.image(bounds, StyOracle.channels(mode, alpha), kind)
                    for method in [WindMethod.wind, .blast] {
                        for right in [false, true] {
                            for seed: UInt32 in [0, 1, 777, .max] {
                                let f = Wind(method: method, fromRight: right, seed: seed)
                                let out = bounds.outset(by: 3)
                                #expect(StyOracle.sameBits(f.cpu(src, out: out, ctx: ctx).data, StyOracle.windStreaks(src, out, ctx, f)!),
                                        "\(mode) alpha \(alpha) kind \(kind) \(method) right \(right) seed \(seed)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func thinAndPartialWindowsMatch() {
        for bounds in [PixelRect(x0: 0, y0: 0, x1: 1, y1: 1), PixelRect(x0: -5, y0: -6, x1: -4, y1: 31), PixelRect(x0: 3, y0: 8, x1: 43, y1: 9)] {
            let ctx = FilterContext(bounds: bounds, mode: .rgb, alpha: true)
            for src in [StyOracle.image(bounds, 4, 0), StyOracle.image(bounds.outset(by: 2), 4, 1)] {
                let out = bounds.outset(by: 2)
                for right in [false, true] {
                    let f = Wind(method: .blast, fromRight: right, seed: 17)
                    #expect(StyOracle.sameBits(f.cpu(src, out: out, ctx: ctx).data, StyOracle.windStreaks(src, out, ctx, f)!))
                }
                for kind in ExtrudeType.allCases {
                    let spec = Extrude(kind: kind, size: 8, depth: 255, levelBased: true, seed: 17)
                    #expect(StyOracle.sameBits(spec.cpu(src, out: out, ctx: ctx).data, StyOracle.extrudeDirect(src, out, ctx, spec)))
                }
            }
        }
    }

    /// photocraft `block_bounds_cover_float_rounding_and_ties`: far from the origin, where f32
    /// pixel centres are coarse, the pruned candidates still cover every hit.
    @Test func blockBoundsCoverFloatRoundingAndTies() {
        for offset: Int32 in [0, -(1 << 22), (1 << 22) - 80] {
            let bounds = PixelRect(x0: offset, y0: offset, x1: offset + 64, y1: offset + 49)
            let ctx = FilterContext(bounds: bounds, mode: .rgb, alpha: true)
            let src = StyOracle.image(bounds, 4, 1)
            for size: Float in [2, 7, 19] {
                let spec = Extrude(kind: .blocks, size: size, depth: 255, levelBased: true, solidFront: true, seed: 42)
                #expect(StyOracle.sameBits(spec.cpu(src, out: bounds, ctx: ctx).data, StyOracle.extrudeDirect(src, bounds, ctx, spec)), "offset \(offset) size \(size)")
            }
        }
    }

    @Test func storageSelectionAndTileSizesMatchOriginalKernels() throws {
        let bounds = PixelRect(x0: -11, y0: -7, x1: 32, y1: 24)
        let area = PixelRect(x0: -9, y0: -5, x1: 29, y1: 21)
        for mode in [ColorMode.rgb, .grayscale, .cmyk, .lab] {
            for sample in [SampleType.u8, .u16, .f32] {
                let fmt = PixelFormat(mode: mode, sample: sample, alpha: true)
                let ctx = FilterContext(bounds: bounds, mode: mode, alpha: true)
                var s = Surface(format: fmt)
                s.writeRegion(bounds, StyOracle.image(bounds, fmt.channels, 3).data)
                var selection = Surface(format: PixelFormat(mode: .grayscale, sample: .f32, alpha: false))
                selection.writeRegion(bounds, (0..<bounds.area).map { Float($0 % 5) / 4 })
                let cov = (0..<area.area).map { i -> Float in
                    let (x, y) = (area.x0 + Int32(i % area.width), area.y0 + Int32(i / area.width))
                    return selection.pixel(x: x, y: y)[0]
                }
                let extrude = Extrude(kind: .blocks, size: 7, depth: 170, levelBased: true, seed: 17)
                let wind = Wind(method: .blast, fromRight: true, seed: 17)
                for (label, run): (String, (inout Surface, Int) throws -> Void) in [
                    ("Extrude", { try FilterEngine.apply(extrude, to: &$0, area: area, bounds: bounds, selection: selection, extent: bounds, on: .cpu, tile: $1) }),
                    ("Wind", { try FilterEngine.apply(wind, to: &$0, area: area, bounds: bounds, selection: selection, extent: bounds, on: .cpu, tile: $1) }),
                ] {
                    let halo: Int32 = label == "Extrude" ? 70 : 41
                    let src = FloatImage(surface: s, rect: area.outset(by: halo), clampedTo: bounds)
                    let rawData = label == "Extrude" ? StyOracle.extrudeDirect(src, area, ctx, extrude) : StyOracle.windStreaks(src, area, ctx, wind)!
                    let raw = FloatImage(rect: area, channels: fmt.channels, data: rawData)
                    let mixed = FilterEngine.mixSelection(original: src.crop(area), filtered: raw, coverage: cov, alpha: true)
                    var want = s
                    want.writeRegion(area, mixed.data)
                    for tile in [16, 17, 256] {
                        var got = s
                        try run(&got, tile)
                        #expect(StyOracle.sameBits(got.readRegion(bounds), want.readRegion(bounds)), "\(mode) \(sample) \(label) tile \(tile)")
                    }
                }
            }
        }
    }
}
