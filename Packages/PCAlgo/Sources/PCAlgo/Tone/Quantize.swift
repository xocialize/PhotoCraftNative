// Port of photocraft-algo (crates/algo/src/quantize.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Colour reduction for Image › Mode › Indexed Color and Bitmap: palette construction (exact,
// system, web, uniform, perceptual, selective, adaptive), forced colours, and dithering (none,
// Floyd–Steinberg diffusion, ordered pattern, noise), plus the 1-bit conversion methods.
// Buffers are straight RGBA in 0…1, row-major. Median cut follows Heckbert (1982); k-means
// refinement is Lloyd's algorithm; error diffusion is Floyd & Steinberg (1976).
//
// GPU: the nearest-colour mapping with None / Pattern / Noise dither and the Threshold / Pattern /
// Halftone bitmap methods are per-pixel Metal kernels (bit-exact with the CPU); palette building
// (a histogram, median cut and a few k-means passes over at most 2²⁴ distinct colours) and the
// error-diffusion methods (serial by nature) stay on the CPU.

import Foundation
import Metal
import PCFoundation

/// photocraft `quantize`: palettes, dithering and Bitmap conversion.
public enum Quantize {
    /// Palette construction (photocraft `PaletteKind`; raw values are its `from_id` ids).
    public enum PaletteKind: String, Codable, Sendable, Hashable, CaseIterable {
        /// Every colour of the image (fails above 256).
        case exact
        case systemMac
        case systemWindows
        case web
        case uniform
        /// Lab median cut + k-means (perceptually weighted).
        case perceptual
        /// Perceptual, with entries near web-safe colours snapped to them.
        case selective
        /// RGB median cut weighted by frequency.
        case adaptive

        /// photocraft `PaletteKind::from_id` (with its aliases).
        public init?(id: String) {
            switch id {
            case "exact": self = .exact
            case "system", "systemMac", "systemMacOs": self = .systemMac
            case "systemWindows": self = .systemWindows
            case "web": self = .web
            case "uniform": self = .uniform
            case "perceptual", "localPerceptual": self = .perceptual
            case "selective", "localSelective": self = .selective
            case "adaptive", "localAdaptive": self = .adaptive
            default: return nil
            }
        }
    }

    /// Forced colours (photocraft `Forced`).
    public enum Forced: String, Codable, Sendable, Hashable, CaseIterable {
        case none, blackWhite, primaries, web
    }

    /// Dither methods (photocraft `Dither`).
    public enum Dither: String, Codable, Sendable, Hashable, CaseIterable {
        case none, diffusion, pattern, noise
    }

    /// Halftone dot shapes (photocraft `HalftoneShape`).
    public enum HalftoneShape: String, Codable, Sendable, Hashable, CaseIterable {
        case round, ellipse, line, square, diamond, cross

        public init?(id: String) { self.init(rawValue: id) }

        var code: UInt32 { UInt32(Self.allCases.firstIndex(of: self)!) }
    }

    /// Image › Mode › Bitmap methods (photocraft `BitmapMethod`).
    public enum BitmapMethod: Codable, Sendable, Hashable {
        case threshold
        case pattern
        case diffusion
        /// Halftone screen: cell size in pixels, angle in degrees, dot shape.
        case halftone(cell: Float, angle: Float, shape: HalftoneShape)
    }

    public enum PaletteError: Error, CustomStringConvertible, Sendable {
        case tooManyColors(Int)
        public var description: String {
            switch self { case .tooManyColors(let n): "the image has \(n) colours; Exact needs 256 or fewer" }
        }
    }

    public typealias Rgb8 = SIMD3<UInt8>

    @inline(__always)
    static func to8(_ v: Float) -> UInt8 { UInt8((clampf(v, 0, 1) * 255).rounded()) }

    @inline(__always)
    static func rgb8(_ p: SIMD4<Float>) -> Rgb8 { Rgb8(to8(p.x), to8(p.y), to8(p.z)) }

    // MARK: Fixed palettes

    /// The 216-colour web-safe cube (0, 51, …, 255 per channel).
    public static func webPalette() -> [Rgb8] {
        var v: [Rgb8] = []
        v.reserveCapacity(216)
        for r in 0..<UInt8(6) { for g in 0..<UInt8(6) { for b in 0..<UInt8(6) { v.append(Rgb8(r * 51, g * 51, b * 51)) } } }
        return v
    }

    /// Classic Mac OS system palette: the web cube plus 10-step red, green, blue and grey ramps.
    public static func macPalette() -> [Rgb8] {
        var v = webPalette()
        let steps: [UInt8] = (1...15).map { UInt8($0 * 17) }.filter { $0 % 51 != 0 }
        for s in steps.reversed() { v.append(Rgb8(s, 0, 0)) }
        for s in steps.reversed() { v.append(Rgb8(0, s, 0)) }
        for s in steps.reversed() { v.append(Rgb8(0, 0, s)) }
        for s in steps.reversed() { v.append(Rgb8(s, s, s)) }
        return Array(v.prefix(256))
    }

    /// Windows default palette: the 20 static system colours plus the web cube and a grey ramp.
    public static func windowsPalette() -> [Rgb8] {
        var v: [Rgb8] = [
            Rgb8(0, 0, 0), Rgb8(128, 0, 0), Rgb8(0, 128, 0), Rgb8(128, 128, 0), Rgb8(0, 0, 128), Rgb8(128, 0, 128),
            Rgb8(0, 128, 128), Rgb8(192, 192, 192), Rgb8(192, 220, 192), Rgb8(166, 202, 240), Rgb8(255, 251, 240),
            Rgb8(160, 160, 164), Rgb8(128, 128, 128), Rgb8(255, 0, 0), Rgb8(0, 255, 0), Rgb8(255, 255, 0), Rgb8(0, 0, 255),
            Rgb8(255, 0, 255), Rgb8(0, 255, 255), Rgb8(255, 255, 255),
        ]
        for c in webPalette() where !v.contains(c) { v.append(c) }
        var g: UInt8 = 8
        while v.count < 256 {
            let c = Rgb8(g, g, g)
            if !v.contains(c) { v.append(c) }
            g = g &+ 12
        }
        return v
    }

    /// Up to `n` colours on an equal-step RGB grid.
    public static func uniformPalette(_ n: Int) -> [Rgb8] {
        let k = max(Int(cbrtf(Float(n)).rounded(.down)), 2)
        let lv = { (i: Int) in UInt8((Float(i) / Float(k - 1) * 255).rounded()) }
        var v: [Rgb8] = []
        for r in 0..<k { for g in 0..<k { for b in 0..<k { v.append(Rgb8(lv(r), lv(g), lv(b))) } } }
        return v
    }

    static func forcedColors(_ f: Forced) -> [Rgb8] {
        switch f {
        case .none: []
        case .blackWhite: [Rgb8(0, 0, 0), Rgb8(255, 255, 255)]
        case .primaries: [Rgb8(0, 0, 0), Rgb8(255, 255, 255), Rgb8(255, 0, 0), Rgb8(0, 255, 0), Rgb8(0, 0, 255),
                          Rgb8(0, 255, 255), Rgb8(255, 0, 255), Rgb8(255, 255, 0)]
        case .web: webPalette()
        }
    }

    // MARK: Computed palettes

    /// Unique 8-bit colours with counts (pixels with alpha ≥ ½), sorted by colour.
    static func histogram(_ px: [SIMD4<Float>]) -> [(Rgb8, UInt32)] {
        var m: [UInt32: UInt32] = [:]
        for p in px where p.w >= 0.5 {
            let c = rgb8(p)
            m[UInt32(c.x) << 16 | UInt32(c.y) << 8 | UInt32(c.z), default: 0] += 1
        }
        return m.sorted { $0.key < $1.key }.map { (Rgb8(UInt8($0.key >> 16), UInt8(($0.key >> 8) & 255), UInt8($0.key & 255)), $0.value) }
    }

    /// Stable sort by one coordinate in IEEE total order (Rust `sort_by(total_cmp)`).
    static func stableSorted(_ b: [(SIMD3<Float>, UInt32)], axis: Int) -> [(SIMD3<Float>, UInt32)] {
        b.enumerated().sorted { x, y in
            let (va, vb) = (x.element.0[axis], y.element.0[axis])
            if va.isTotallyOrdered(belowOrEqualTo: vb) && vb.isTotallyOrdered(belowOrEqualTo: va) { return x.offset < y.offset }
            return va.isTotallyOrdered(belowOrEqualTo: vb)
        }.map(\.element)
    }

    /// Median cut over weighted feature vectors into at most `n` boxes; returns box means.
    static func medianCut(_ pts: [(SIMD3<Float>, UInt32)], _ n: Int) -> [SIMD3<Float>] {
        if pts.isEmpty || n == 0 { return [] }
        var boxes: [[(SIMD3<Float>, UInt32)]] = [pts]
        while boxes.count < n {
            // Split the box with the largest weighted extent.
            var sel: (Int, Int, Float) = (Int.max, 0, -1)
            for (i, b) in boxes.enumerated() where b.count > 1 {
                var best: (Int, Float) = (0, -1)
                for a in 0..<3 {
                    var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
                    for p in b { lo = Float.minimum(lo, p.0[a]); hi = Float.maximum(hi, p.0[a]) }
                    if hi - lo > best.1 { best = (a, hi - lo) }
                }
                var w: Float = 0
                for p in b { w += Float(p.1) }
                let score = best.1 * w.squareRoot()
                if score > sel.2 { sel = (i, best.0, score) }
            }
            let (bi, axis, score) = sel
            if bi == Int.max || score <= 0 { break }
            // `swap_remove`.
            var b = boxes[bi]
            if bi == boxes.count - 1 { boxes.removeLast() } else { boxes[bi] = boxes.removeLast() }
            b = stableSorted(b, axis: axis)
            var total: UInt64 = 0
            for p in b { total += UInt64(p.1) }
            var acc: UInt64 = 0
            var cut = 1
            for (i, p) in b.enumerated() {
                acc += UInt64(p.1)
                if acc * 2 >= total { cut = min(max(i + 1, 1), b.count - 1); break }
            }
            let rest = Array(b[cut...])
            b.removeSubrange(cut...)
            boxes.append(b)
            boxes.append(rest)
        }
        return boxes.map { b in
            var w = 0.0
            for p in b { w += Double(p.1) }
            var m = SIMD3<Float>()
            for a in 0..<3 {
                var s = 0.0
                for p in b { s += Double(p.0[a]) * Double(p.1) }
                m[a] = Float(s / w)
            }
            return m
        }
    }

    /// Lloyd refinement of `centers` over weighted points.
    static func kmeans(_ pts: [(SIMD3<Float>, UInt32)], _ centers: inout [SIMD3<Float>], _ iters: Int) {
        // No room left (the forced colours fill the palette): nothing to refine.
        if centers.isEmpty { return }
        for _ in 0..<iters {
            let lookup = Nearest(centers)
            var sum = [SIMD3<Double>](repeating: .zero, count: centers.count)
            var cnt = [Double](repeating: 0, count: centers.count)
            for (p, w) in pts {
                let i = lookup.find(p)
                for a in 0..<3 { sum[i][a] += Double(p[a]) * Double(w) }
                cnt[i] += Double(w)
            }
            for i in 0..<centers.count where cnt[i] > 0 {
                centers[i] = SIMD3(Float(sum[i].x / cnt[i]), Float(sum[i].y / cnt[i]), Float(sum[i].z / cnt[i]))
            }
        }
    }

    static func labToRGB8(_ lab: SIMD3<Float>) -> Rgb8 {
        let c = ColorConvert.labToSRGB(lab)
        return Rgb8(to8(c.x), to8(c.y), to8(c.z))
    }

    /// Builds the palette for `px` (photocraft `build_palette`). `colors` is the requested count
    /// (2…256) for the computed kinds; forced colours come first and count toward it.
    public static func buildPalette(_ px: [SIMD4<Float>], kind: PaletteKind, colors: Int, forced: Forced) throws -> [Rgb8] {
        let colors = min(max(colors, 2), 256)
        var pal = forcedColors(forced)
        let room = max(colors - pal.count, 0)
        // Fixed palettes, or computed ones already filled by forced colours, need no scan; Exact
        // still counts every colour to enforce its 256-colour limit.
        let hist = kind == .exact || (room > 0 && [.adaptive, .perceptual, .selective].contains(kind)) ? histogram(px) : []
        let computed: [Rgb8]
        switch kind {
        case .exact:
            if hist.count > 256 { throw PaletteError.tooManyColors(hist.count) }
            computed = hist.map(\.0)
        case .systemMac: computed = macPalette()
        case .systemWindows: computed = windowsPalette()
        case .web: computed = webPalette()
        case .uniform: computed = uniformPalette(max(room, 8))
        case .adaptive:
            if hist.count <= room { computed = hist.map(\.0) } else {
                let pts = hist.map { (SIMD3(Float($0.0.x), Float($0.0.y), Float($0.0.z)), $0.1) }
                var centers = medianCut(pts, room)
                kmeans(pts, &centers, 2)
                computed = centers.map { c in Rgb8(UInt8(clampf(c.x.rounded(), 0, 255)), UInt8(clampf(c.y.rounded(), 0, 255)), UInt8(clampf(c.z.rounded(), 0, 255))) }
            }
        case .perceptual, .selective:
            if hist.count <= room { computed = hist.map(\.0) } else {
                let pts = hist.map { (ColorConvert.srgbToLab(SIMD3(Float($0.0.x) / 255, Float($0.0.y) / 255, Float($0.0.z) / 255)), $0.1) }
                var centers = medianCut(pts, room)
                kmeans(pts, &centers, 4)
                var v = centers.map(labToRGB8)
                if kind == .selective {
                    // Favour web-safe colours: snap entries within ~10 levels of one.
                    for i in 0..<v.count {
                        let c = v[i]
                        let snap = Rgb8((0..<3).map { UInt8((Float(c[$0]) / 51).rounded() * 51) })
                        if (0..<3).allSatisfy({ abs(Int(c[$0]) - Int(snap[$0])) <= 10 }) { v[i] = snap }
                    }
                }
                computed = v
            }
        }
        for c in computed {
            if pal.count >= 256 { break }
            if !pal.contains(c) { pal.append(c) }
        }
        if [.adaptive, .perceptual, .selective, .uniform].contains(kind) {
            pal = Array(pal.prefix(max(colors, forcedColors(forced).count)))
        }
        if pal.isEmpty { pal.append(Rgb8(0, 0, 0)) }
        return pal
    }

    // MARK: Dithering

    static let bayer: [UInt8] = [
        0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22, 3, 35, 11, 43, 1, 33, 9, 41,
        51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
    ]

    /// 8×8 Bayer threshold in −0.5…0.5.
    @inline(__always)
    public static func bayer8(_ x: Int, _ y: Int) -> Float { (Float(bayer[(y % 8) * 8 + x % 8]) + 0.5) / 64 - 0.5 }

    /// quantize.rs's own position hash → 0…1.
    @inline(__always)
    static func hash01(_ x: Int, _ y: Int, _ seed: UInt32) -> Float {
        var h = UInt32(truncatingIfNeeded: x) &* 0x8da6_b343 ^ UInt32(truncatingIfNeeded: y) &* 0xd816_3841 ^ seed &* 0xcb1a_b31f
        h ^= h >> 13
        h = h &* 0x5bd1_e995
        h ^= h >> 15
        return Float(h & 0xffff) / 65535
    }

    /// The ordered/noise dither amplitude from the typical palette spacing.
    static func spread(_ count: Int, _ amount: Float) -> Float {
        Float.minimum(1 / Float.maximum(cbrtf(Float(count)), 1), 0.5) * clampf(amount, 0, 1)
    }

    /// Maps every opaque pixel to its palette entry (in place) with the chosen dither; returns the
    /// index per pixel. Pixels with alpha < ½ become index `transparent` (and alpha 0) when given;
    /// otherwise alpha is kept. `amount` (0…1) scales diffusion / pattern / noise strength
    /// (photocraft `quantize`).
    @discardableResult
    public static func quantize(_ px: inout [SIMD4<Float>], w: Int, palette pal: [Rgb8], dither: Dither, amount: Float,
                                transparent: Int?) -> [UInt8] {
        let lookup = Nearest(pal.map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) })
        return quantizeWith(&px, w, pal, dither, amount, transparent) { lookup.find($0 * 255) }
    }

    static func quantizeWith(_ px: inout [SIMD4<Float>], _ w: Int, _ pal: [Rgb8], _ dither: Dither, _ amount: Float, _ transparent: Int?,
                             _ nearest: @escaping @Sendable (SIMD3<Float>) -> Int) -> [UInt8] {
        let h = w > 0 ? px.count / w : 0
        var idx = [UInt8](repeating: 0, count: px.count)
        let spr = spread(pal.count, amount)
        let palF = pal.map { SIMD3(Float($0.x) / 255, Float($0.y) / 255, Float($0.z) / 255) }
        if dither != .diffusion {
            // No cross-pixel dependency: map every pixel in parallel.
            px.withUnsafeMutableBufferPointer { pb in
                idx.withUnsafeMutableBufferPointer { ib in
                    let (ps, isx) = (UnsafeSendable(pb), UnsafeSendable(ib))
                    parallelChunks(h, minChunk: 4) { rows in
                        for y in rows {
                            for x in 0..<w {
                                let i = y * w + x
                                let pv = ps.value[i]
                                if pv.w < 0.5 {
                                    if let t = transparent {
                                        isx.value[i] = UInt8(truncatingIfNeeded: t)
                                        ps.value[i] = .zero
                                        continue
                                    }
                                    if pv.w <= 0 { continue }
                                }
                                var c = SIMD3(pv.x, pv.y, pv.z)
                                switch dither {
                                case .pattern: let t = bayer8(x, y) * spr; c = SIMD3(c.x + t, c.y + t, c.z + t)
                                case .noise: let t = (hash01(x, y, 7) - 0.5) * spr; c = SIMD3(c.x + t, c.y + t, c.z + t)
                                default: break
                                }
                                c = SIMD3(clampf(c.x, 0, 1), clampf(c.y, 0, 1), clampf(c.z, 0, 1))
                                let k = nearest(c)
                                isx.value[i] = UInt8(truncatingIfNeeded: k)
                                ps.value[i] = SIMD4(palF[k], transparent != nil ? 1 : pv.w)
                            }
                        }
                    }
                }
            }
            return idx
        }
        // Floyd–Steinberg: rows ping-pong (`cur` row y, `next` row y + 1, offset by one for x = −1).
        var cur = [SIMD3<Float>](repeating: .zero, count: w + 2), next = cur
        let a = clampf(amount, 0, 1)
        for y in 0..<h {
            cur = next
            for i in 0..<next.count { next[i] = .zero }
            for x in 0..<w {
                let i = y * w + x
                let p = px[i]
                if p.w < 0.5 {
                    if let t = transparent {
                        idx[i] = UInt8(truncatingIfNeeded: t)
                        px[i] = .zero
                        continue
                    }
                    if p.w <= 0 { continue }
                }
                var c = SIMD3(p.x + cur[x + 1].x, p.y + cur[x + 1].y, p.z + cur[x + 1].z)
                c = SIMD3(clampf(c.x, 0, 1), clampf(c.y, 0, 1), clampf(c.z, 0, 1))
                let k = nearest(c)
                idx[i] = UInt8(truncatingIfNeeded: k)
                let e = palF[k]
                let d = SIMD3((c.x - e.x) * a, (c.y - e.y) * a, (c.z - e.z) * a)
                for q in 0..<3 {
                    cur[x + 2][q] += d[q] * 7 / 16
                    next[x][q] += d[q] * 3 / 16
                    next[x + 1][q] += d[q] * 5 / 16
                    next[x + 2][q] += d[q] / 16
                }
                px[i] = SIMD4(e, transparent != nil ? 1 : p.w)
            }
        }
        return idx
    }

    // MARK: Bitmap

    /// Spot function in 0…1 for a position (u, v) in −1…1 within a halftone cell.
    @inline(__always)
    static func spot(_ shape: HalftoneShape, _ u: Float, _ v: Float) -> Float {
        let s: Float
        switch shape {
        case .round: s = 1 - (u * u + v * v) / 2
        case .ellipse: s = 1 - (u * u + 0.6 * v * v) / 1.6
        case .line: s = 1 - abs(v)
        case .square: s = 1 - Float.maximum(abs(u), abs(v))
        case .diamond: s = 1 - (abs(u) + abs(v)) / 2
        case .cross: s = 1 - Float.minimum(abs(u), abs(v))
        }
        return clampf(s, 0, 1)
    }

    /// The spot function ranked over the cell (32 × 32 samples, sorted) so coverage is
    /// proportional to the tone.
    static func spotTable(_ shape: HalftoneShape) -> [Float] {
        let t = (0..<(32 * 32)).map { k in spot(shape, (Float(k % 32) + 0.5) / 16 - 1, (Float(k / 32) + 0.5) / 16 - 1) }
        return ToneKit.totalSorted(t)
    }

    /// Converts grey values (0…1, row-major `w` wide) to 0/1 in place (photocraft `to_bitmap`).
    public static func toBitmap(_ gray: inout [Float], w: Int, method: BitmapMethod) {
        let h = w > 0 ? gray.count / w : 0
        switch method {
        case .threshold:
            for i in 0..<gray.count { gray[i] = gray[i] >= 0.5 ? 1 : 0 }
        case .pattern:
            for i in 0..<gray.count { gray[i] = gray[i] > bayer8(i % w, i / w) + 0.5 ? 1 : 0 }
        case .diffusion:
            var buf = gray
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let old = buf[i]
                    let new: Float = old >= 0.5 ? 1 : 0
                    let e = old - new
                    gray[i] = new
                    if x + 1 < w { buf[i + 1] += e * 7 / 16 }
                    if y + 1 < h {
                        if x > 0 { buf[i + w - 1] += e * 3 / 16 }
                        buf[i + w] += e * 5 / 16
                        if x + 1 < w { buf[i + w + 1] += e / 16 }
                    }
                }
            }
        case .halftone(let cell0, let angle, let shape):
            let cell = Float.maximum(cell0, 2)
            let rad = PCAMath.radians(angle)
            let (s, c) = (sinf(rad), cosf(rad))
            let table = spotTable(shape)
            gray.withUnsafeMutableBufferPointer { g in
                let gs = UnsafeSendable(g)
                parallelChunks(g.count, minChunk: 4096) { r in
                    for i in r { gs.value[i] = halftonePixel(i, w, gs.value[i], cell, s, c, shape, table) }
                }
            }
        }
    }

    @inline(__always)
    static func halftonePixel(_ i: Int, _ w: Int, _ v: Float, _ cell: Float, _ s: Float, _ c: Float, _ shape: HalftoneShape, _ table: [Float]) -> Float {
        let x = Float(i % w) + 0.5, y = Float(i / w) + 0.5
        let rx = x * c + y * s, ry = -x * s + y * c
        let u = euclidMod(rx / cell, 1) * 2 - 1
        let vv = euclidMod(ry / cell, 1) * 2 - 1
        // Ink (black) covers where the spot function exceeds the grey level.
        let sp = spot(shape, u, vv)
        var lo = 0, hi = table.count
        while lo < hi { let m = (lo + hi) / 2; if table[m] < sp { lo = m + 1 } else { hi = m } }
        return Float(lo) / Float(table.count) >= v ? 0 : 1
    }
}
