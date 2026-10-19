// Port of photocraft-algo (crates/algo/src/selection.rs: mask_from_surface, surface_from_masks, mask_to_surface, combine, rgba8_image, wand_region, combine_region; selection/marquee.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Selections as GRAY8 surfaces: masks to and from tiles (only tiles holding something are kept),
// combining a new mask or region with the current selection, the 8-bit magic wand (a scanline
// flood fill that allocates one byte per pixel), the Elliptical Marquee built tile by tile, and
// the tile-wise combination of two selections. CPU only: these are data-structure operations on
// sparse tiles; the per-pixel work is a table lookup.

import Foundation
import PCFoundation

extension Selection {
    // MARK: Masks ↔ surfaces

    /// Reads a selection surface over `area` (no selection → all zero).
    public static func maskFromSurface(_ s: Surface?, area: PixelRect) -> [Float] {
        let n = area.area
        guard let s else { return [Float](repeating: 0, count: n) }
        if s.format == .gray8 && !area.isEmpty {
            let w = area.width, ts = Int(tileSize)
            let dp = s.defaultPixelValue.first ?? 0
            var out = [Float](repeating: 0, count: n)
            out.withUnsafeMutableBufferPointer { ob in
                let o = UnsafeSendable(ob)
                parallelChunks(area.height, minChunk: 8) { rows in
                    for yy in rows {
                        let y = area.y0 + Int32(yy)
                        var x = area.x0
                        while x < area.x1 {
                            let tc = TileCoord(containing: x, y)
                            let x1 = min(tc.rect.x1, area.x1)
                            let d0 = yy * w + Int(x - area.x0), len = Int(x1 - x)
                            if let t = s.tile(tc) {
                                let base = Int(y - tc.ty * tileSize) * ts + Int(x - tc.tx * tileSize)
                                t.bytes.withUnsafeBufferPointer { b in
                                    for k in 0..<len { o.value[d0 + k] = Float(b[base + k]) / 255 }
                                }
                            } else {
                                for k in 0..<len { o.value[d0 + k] = dp }
                            }
                            x = x1
                        }
                    }
                }
            }
            return out
        }
        let v = s.readRegion(area)
        let ch = s.channels
        return ch > 1 ? stride(from: 0, to: v.count, by: ch).map { v[$0] } : v
    }

    /// A GRAY8 selection over `area` whose byte at each sample is `coverage8(f(prev, new))`
    /// (missing samples read 0); only tiles holding something are kept (photocraft
    /// `surface_from_masks`).
    static func surfaceFromMasks(_ area: PixelRect, _ new: [Float], _ prev: [Float]?, _ f: @escaping @Sendable (Float, Float) -> Float) -> Surface {
        var s = Surface(format: .gray8)
        if area.isEmpty { return s }
        let w = area.width, ts = Int(tileSize)
        let coords = area.tiles
        var built = [Tile?](repeating: nil, count: coords.count)
        built.withUnsafeMutableBufferPointer { bb in
            let b = UnsafeSendable(bb)
            new.withUnsafeBufferPointer { nb in
                let pv = prev ?? []
                pv.withUnsafeBufferPointer { pb in
                    parallelFor(coords.count) { k in
                        let tc = coords[k]
                        let tr = tc.rect.intersect(area)
                        var bytes = [UInt8](repeating: 0, count: ts * ts)
                        var hi: UInt8 = 0
                        for y in tr.y0..<tr.y1 {
                            let o = Int(y - tc.ty * tileSize) * ts + Int(tr.x0 - tc.tx * tileSize)
                            let i0 = Int(y - area.y0) * w + Int(tr.x0 - area.x0)
                            for j in 0..<tr.width {
                                let i = i0 + j
                                let nv: Float = i < nb.count ? nb[i] : 0
                                let pvv: Float = prev == nil ? 0 : (i < pb.count ? pb[i] : 0)
                                let v = SelectionKit.coverage8(f(pvv, nv))
                                bytes[o + j] = v
                                hi = max(hi, v)
                            }
                        }
                        if hi > 0 { b.value[k] = Tile(bytes: bytes) }
                    }
                }
            }
        }
        s.putTiles(zip(coords, built).compactMap { c, t in t.map { (c, $0) } })
        return s
    }

    /// A GRAY8 selection surface from a mask over `area` (missing samples are 0).
    public static func maskToSurface(_ m: [Float], area: PixelRect) -> Surface {
        surfaceFromMasks(area, m, nil) { _, v in v }
    }

    /// Combines `new` (a mask over `area`) with `old` by `mode`; nil when nothing is selected.
    /// The new mask is quantised to the 8-bit grid first, so combining a mask with itself is exact.
    public static func combine(_ old: Surface?, _ new: [Float], area: PixelRect, mode: SelectionMode) -> Surface? {
        if area.isEmpty { return nil }
        let q: @Sendable (Float) -> Float = { Float(SelectionKit.coverage8($0)) / 255 }
        let s: Surface
        switch mode {
        case .replace: s = surfaceFromMasks(area, new, nil) { _, v in v }
        case .add: s = surfaceFromMasks(area, new, maskFromSurface(old, area: area)) { p, v in Float.maximum(p, q(v)) }
        case .subtract: s = surfaceFromMasks(area, new, maskFromSurface(old, area: area)) { p, v in Float.maximum(p - q(v), 0) }
        case .intersect: s = surfaceFromMasks(area, new, maskFromSurface(old, area: area)) { p, v in Float.minimum(p, q(v)) }
        }
        return s.tileCount > 0 ? s : nil
    }

    /// Straight RGBA8 copy of `area` of a surface (any format, converted; photocraft `rgba8_image`).
    public static func rgba8Image(_ s: Surface, area: PixelRect) -> [SIMD4<UInt8>] {
        if area.isEmpty { return [] }
        let f = s.readRGBA(area)
        return f.map { p in SIMD4(SelectionKit.coverage8(p.x), SelectionKit.coverage8(p.y), SelectionKit.coverage8(p.z), SelectionKit.coverage8(p.w)) }
    }

    // MARK: 8-bit magic wand

    /// The colour the Magic Wand matches for a click at `seed` with Photoshop's Sample Size: the pixel itself for a
    /// `size` of 1 (Point Sample), else the average of the `size` × `size` square around it ("3 by 3 Average" …
    /// "101 by 101 Average"), cut to `area`. Colour is averaged weighted by alpha, so the RGB under transparent pixels
    /// doesn't count; alpha is the plain mean. Each rounds to the nearest level. Nil if the seed is outside `area`.
    public static func wandSample(_ img: [SIMD4<UInt8>], area: PixelRect, seed: (x: Int32, y: Int32), size: Int) -> SIMD4<UInt8>? {
        guard area.contains(x: seed.x, y: seed.y), img.count == area.area else { return nil }
        let w = area.width, h = area.height
        let sx = Int(seed.x - area.x0), sy = Int(seed.y - area.y0)
        let r = max(size, 1) / 2
        if r == 0 { return img[sy * w + sx] }
        var rgb = SIMD3<UInt64>(repeating: 0), alpha: UInt64 = 0, n: UInt64 = 0
        for y in max(sy - r, 0)...min(sy + r, h - 1) {
            for x in max(sx - r, 0)...min(sx + r, w - 1) {
                let p = img[y * w + x], a = UInt64(p.w)
                rgb &+= SIMD3(UInt64(p.x), UInt64(p.y), UInt64(p.z)) &* a
                alpha += a
                n += 1
            }
        }
        let c: SIMD3<UInt64> = alpha == 0 ? .zero : (rgb &+ alpha / 2) / alpha
        return SIMD4(UInt8(c.x), UInt8(c.y), UInt8(c.z), UInt8((alpha + n / 2) / n))
    }

    /// Magic wand on 8-bit pixels (photocraft `wand_region`): a scanline flood fill (or a global
    /// match) marking one byte per pixel, then anti-aliasing only the edges inside the touched
    /// bounding box. Matches `magicWand` for 8-bit sources; nil if the seed is outside `area`.
    /// `target` is the colour to match (`wandSample`'s average), the seed's own by default; a contiguous fill whose
    /// seed doesn't match it selects nothing (nil).
    public static func wandRegion(_ img: [SIMD4<UInt8>], area: PixelRect, seed: (x: Int32, y: Int32), tolerance: Float,
                                  contiguous: Bool, antiAlias: Bool, target: SIMD4<UInt8>? = nil) -> SelectionRegion? {
        if !area.contains(x: seed.x, y: seed.y) { return nil }
        let w = area.width, h = area.height
        let target = target ?? img[Int(seed.y - area.y0) * w + Int(seed.x - area.x0)]
        let tol = Int(SelectionKit.i32Cast(Float.maximum((tolerance + 1e-3).rounded(.down), 0)))
        // Copied selections can leave RGB under zero alpha: invisible colours must not split a
        // transparent region.
        @inline(__always) func similar(_ p: SIMD4<UInt8>) -> Bool {
            if target.w == 0 && p.w == 0 { return true }
            return abs(Int(p.x) - Int(target.x)) <= tol && abs(Int(p.y) - Int(target.y)) <= tol
                && abs(Int(p.z) - Int(target.z)) <= tol && abs(Int(p.w) - Int(target.w)) <= tol
        }
        var marks = [UInt8](repeating: 0, count: w * h)
        var bx0 = Int.max, by0 = Int.max, bx1 = 0, by1 = 0
        if contiguous {
            if !similar(img[Int(seed.y - area.y0) * w + Int(seed.x - area.x0)]) { return nil }
            // Span fill: fill a run, then scan the rows above and below it for new seeds.
            var stack: [(Int, Int)] = [(Int(seed.x - area.x0), Int(seed.y - area.y0))]
            while let top = stack.popLast() {
                let (x, y) = top
                let row = y * w
                if marks[row + x] != 0 { continue }
                var l = x, r = x
                while l > 0 && marks[row + l - 1] == 0 && similar(img[row + l - 1]) { l -= 1 }
                while r + 1 < w && marks[row + r + 1] == 0 && similar(img[row + r + 1]) { r += 1 }
                for i in (row + l)...(row + r) { marks[i] = 255 }
                bx0 = min(bx0, l); bx1 = max(bx1, r); by0 = min(by0, y); by1 = max(by1, y)
                for ny in [y - 1, y + 1] where ny >= 0 && ny < h {
                    let nrow = ny * w
                    var inRun = false
                    for nx in l...r {
                        let ok = marks[nrow + nx] == 0 && similar(img[nrow + nx])
                        if ok && !inRun { stack.append((nx, ny)) }
                        inRun = ok
                    }
                }
            }
        } else {
            var spans = [(Int, Int)?](repeating: nil, count: h)
            marks.withUnsafeMutableBufferPointer { mb in
                let m = UnsafeSendable(mb)
                spans.withUnsafeMutableBufferPointer { sb in
                    let sp = UnsafeSendable(sb)
                    img.withUnsafeBufferPointer { p in
                        parallelChunks(h, minChunk: 8) { rows in
                            for y in rows {
                                var span: (Int, Int)?
                                for x in 0..<w where similar(p[y * w + x]) {
                                    m.value[y * w + x] = 255
                                    span = (span?.0 ?? x, x)
                                }
                                sp.value[y] = span
                            }
                        }
                    }
                }
            }
            for (y, sp) in spans.enumerated() {
                if let s = sp { bx0 = min(bx0, s.0); bx1 = max(bx1, s.1); by0 = min(by0, y); by1 = max(by1, y) }
            }
        }
        if bx0 == Int.max { return nil }
        // One pixel of fringe for anti-aliasing, clamped to the area.
        let pad = antiAlias ? 1 : 0
        let x0 = max(bx0 - pad, 0), y0 = max(by0 - pad, 0)
        let x1 = min(bx1 + 1 + pad, w), y1 = min(by1 + 1 + pad, h)
        let bw = x1 - x0
        var mask = [UInt8](repeating: 0, count: bw * (y1 - y0))
        mask.withUnsafeMutableBufferPointer { ob in
            let o = UnsafeSendable(ob)
            marks.withUnsafeBufferPointer { mk in
                parallelChunks(y1 - y0, minChunk: 8) { rows in
                    for yy in rows {
                        let y = y0 + yy
                        for xx in 0..<bw {
                            let x = x0 + xx
                            let v = mk[y * w + x]
                            var out = v
                            if antiAlias {
                                // Same rule as `antialias`: edge pixels blend with their 3×3
                                // neighbourhood; neighbours outside the area count as the pixel.
                                var sum: UInt32 = 0
                                var edge = false
                                for dy in -1...1 {
                                    for dx in -1...1 {
                                        let nx = x + dx, ny = y + dy
                                        let nv = nx < 0 || ny < 0 || nx >= w || ny >= h ? v : mk[ny * w + nx]
                                        edge = edge || nv != v
                                        sum += UInt32(nv)
                                    }
                                }
                                if edge {
                                    let avg = Float(sum) / (9 * 255)
                                    let f: Float = v > 127 ? 0.5 + 0.5 * avg : 0.5 * avg
                                    out = SelectionKit.u8Cast((f * 255).rounded())
                                }
                            }
                            o.value[yy * bw + xx] = out
                        }
                    }
                }
            }
        }
        let bbox = PixelRect(x0: area.x0 + Int32(x0), y0: area.y0 + Int32(y0), x1: area.x0 + Int32(x1), y1: area.y0 + Int32(y1))
        return SelectionRegion(bbox: bbox, mask: mask)
    }

    /// Combines a region with the current selection, touching only the region's box (outside it
    /// the new mask is zero); nil when nothing remains selected (photocraft `combine_region`).
    public static func combineRegion(_ old: Surface?, _ new: SelectionRegion?, mode: SelectionMode) -> Surface? {
        let region = new ?? SelectionRegion(bbox: .empty, mask: [])
        let b = region.bbox
        func prevU8(_ s: Surface) -> [UInt8] {
            let v = s.readRegion(b)
            let ch = s.channels
            return stride(from: 0, to: v.count, by: ch).map { SelectionKit.u8Cast((clampf(v[$0], 0, 1) * 255).rounded()) }
        }
        func fromBytes(_ bytes: [UInt8]) -> Surface? {
            if b.isEmpty || bytes.allSatisfy({ $0 == 0 }) { return nil }
            var s = Surface(format: .gray8, rect: b, interleaved: bytes)
            s.prune()
            return s
        }
        func nonempty(_ s: Surface) -> Surface? { s.contentBounds.isEmpty ? nil : s }
        switch (mode, old) {
        case (.replace, _), (.add, nil): return fromBytes(region.mask)
        case (.subtract, nil), (.intersect, nil): return nil
        case (.intersect, let o?):
            let p = prevU8(o)
            return fromBytes(zip(p, region.mask).map { min($0, $1) })
        case (_, let o?):
            if b.isEmpty { return nonempty(o) }
            let p = prevU8(o)
            let out: [Float] = zip(p, region.mask).map { a, n in Float(mode == .add ? max(a, n) : (a > n ? a - n : 0)) / 255 }
            var s = o
            s.writeRegion(b, out)
            s.prune()
            return nonempty(s)
        }
    }

    // MARK: Marquee (selection/marquee.rs)

    /// The Elliptical Marquee's shape: the ellipse inscribed in `r`, cut to `clip`, as a GRAY8
    /// selection. Anti-aliased edge pixels hold the fraction of their 4×4 sub-samples inside;
    /// without anti-aliasing a pixel is selected when its centre is inside. Tiles inside the
    /// ellipse are filled without testing pixels (photocraft `ellipse_surface`).
    public static func ellipseSurface(_ r: PixelRect, clip: PixelRect, antiAlias: Bool) -> Surface {
        var s = Surface(format: .gray8)
        let cut = r.intersect(clip)
        if cut.isEmpty { return s }
        let e = SelectionKit.Ellipse(r)
        let enc = (0...16).map { SelectionKit.coverage8(Float($0) / 16) }
        let one = SelectionKit.coverage8(1)
        var rows = [SelectionKit.RowSpan](repeating: .init(lo: 0, fullLo: 0, fullHi: 0, hi: 0), count: cut.height)
        rows.withUnsafeMutableBufferPointer { rb in
            let rr = UnsafeSendable(rb)
            parallelChunks(cut.height, minChunk: 16) { range in
                for i in range { rr.value[i] = SelectionKit.rowSpan(e, cut.y0 + Int32(i), cut, antiAlias) }
            }
        }
        let ts = Int(tileSize)
        let coords = cut.tiles
        let fullTile = Tile(bytes: [UInt8](repeating: one, count: ts * ts))
        var built = [Tile?](repeating: nil, count: coords.count)
        built.withUnsafeMutableBufferPointer { bb in
            let b = UnsafeSendable(bb)
            rows.withUnsafeBufferPointer { sp in
                parallelFor(coords.count) { k in
                    let tc = coords[k]
                    let rect = tc.rect
                    let tr = rect.intersect(cut)
                    if tr == rect && (tr.y0..<tr.y1).allSatisfy({ let s = sp[Int($0 - cut.y0)]; return s.fullLo <= tr.x0 && s.fullHi >= tr.x1 }) {
                        b.value[k] = fullTile
                        return
                    }
                    var bytes: [UInt8]?
                    for y in tr.y0..<tr.y1 {
                        let s = sp[Int(y - cut.y0)]
                        let row = Int(y - rect.y0) * ts
                        @inline(__always) func at(_ x: Int32) -> Int { row + Int(x - rect.x0) }
                        let a = max(s.fullLo, tr.x0), z = min(s.fullHi, tr.x1)
                        if a < z {
                            if bytes == nil { bytes = [UInt8](repeating: 0, count: ts * ts) }
                            for x in a..<z { bytes![at(x)] = one }
                        }
                        let edges = [(max(s.lo, tr.x0), min(s.fullLo, tr.x1)), (max(s.fullHi, tr.x0), min(s.hi, tr.x1))]
                        for (e0, e1) in edges where e0 < e1 {
                            for x in e0..<e1 {
                                let n = e.coverage(x, y, antiAlias)
                                if n > 0 {
                                    if bytes == nil { bytes = [UInt8](repeating: 0, count: ts * ts) }
                                    bytes![at(x)] = enc[Int(n)]
                                }
                            }
                        }
                    }
                    if let bytes { b.value[k] = Tile(bytes: bytes) }
                }
            }
        }
        s.putTiles(zip(coords, built).compactMap { c, t in t.map { (c, $0) } })
        return s
    }

    /// `f(a, b)` per pixel over `area` for two selections, as a GRAY8 selection holding nothing
    /// outside `area` (photocraft `combine_surfaces`): GRAY8 inputs go tile by tile through a table
    /// of all 256×256 byte pairs.
    public static func combineSurfaces(_ a: Surface, _ b: Surface, area: PixelRect, _ f: (Float, Float) -> Float) -> Surface {
        var out = Surface(format: .gray8)
        if area.isEmpty { return out }
        if a.format != .gray8 || b.format != .gray8 {
            let ra = a.readRegion(area), rb = b.readRegion(area)
            let data = zip(ra, rb).map { f($0, $1) }
            if data.count == area.area {
                out.writeRegion(area, data)
                out.prune()
            }
            return out
        }
        var lut = [UInt8](repeating: 0, count: 1 << 16)
        for i in 0..<(1 << 16) { lut[i] = SelectionKit.coverage8(f(Float(i >> 8) / 255, Float(i & 0xff) / 255)) }
        let da = a.defaultPixel.first ?? 0, db = b.defaultPixel.first ?? 0
        let ts = Int(tileSize)
        let coords = area.tiles
        var built = [Tile?](repeating: nil, count: coords.count)
        built.withUnsafeMutableBufferPointer { bb in
            let bv = UnsafeSendable(bb)
            lut.withUnsafeBufferPointer { l in
                parallelFor(coords.count) { k in
                    let tc = coords[k]
                    let rect = tc.rect, tr = rect.intersect(area)
                    let ta = a.tile(tc), tb = b.tile(tc)
                    if ta == nil && tb == nil && l[Int(da) << 8 | Int(db)] == 0 { return }
                    var bytes = [UInt8](repeating: 0, count: ts * ts)
                    var hi: UInt8 = 0
                    let x0 = Int(tr.x0 - rect.x0), x1 = Int(tr.x1 - rect.x0)
                    for ly in Int(tr.y0 - rect.y0)..<Int(tr.y1 - rect.y0) {
                        for lx in x0..<x1 {
                            let o = ly * ts + lx
                            let va = ta.map { $0.bytes[o] } ?? da, vb = tb.map { $0.bytes[o] } ?? db
                            let v = l[Int(va) << 8 | Int(vb)]
                            bytes[o] = v
                            hi = max(hi, v)
                        }
                    }
                    if hi > 0 { bv.value[k] = Tile(bytes: bytes) }
                }
            }
        }
        out.putTiles(zip(coords, built).compactMap { c, t in t.map { (c, $0) } })
        return out
    }
}

extension SelectionKit {
    /// An ellipse inscribed in a rectangle, tested in Float exactly as the Elliptical Marquee
    /// always has (photocraft `marquee::Ellipse`).
    struct Ellipse: Sendable {
        var cx: Float, cy: Float, rx: Float, ry: Float

        init(_ r: PixelRect) {
            cx = Float(Int64(r.x0) + Int64(r.x1)) / 2
            cy = Float(Int64(r.y0) + Int64(r.y1)) / 2
            rx = Float(r.width) / 2
            ry = Float(r.height) / 2
        }

        @inline(__always)
        func inside(_ x: Float, _ y: Float) -> Bool {
            let dx = (x - cx) / rx, dy = (y - cy) / ry
            return dx * dx + dy * dy <= 1
        }

        /// Whether every point of pixel (x, y) the coverage samples is inside (its four corners
        /// anti-aliased, else its centre).
        @inline(__always)
        func full(_ x: Int32, _ y: Int32, _ aa: Bool) -> Bool {
            let fx = Float(x), fy = Float(y)
            if !aa { return inside(fx + 0.5, fy + 0.5) }
            return inside(fx, fy) && inside(fx + 1, fy) && inside(fx, fy + 1) && inside(fx + 1, fy + 1)
        }

        /// Coverage in sixteenths: 16 when `full`, else (anti-aliased) the 4×4 sub-samples inside.
        @inline(__always)
        func coverage(_ x: Int32, _ y: Int32, _ aa: Bool) -> UInt8 {
            if full(x, y, aa) { return 16 }
            if !aa { return 0 }
            let fx = Float(x), fy = Float(y)
            var n: UInt8 = 0
            for i in 0..<16 where inside(fx + (Float(i % 4) + 0.5) / 4, fy + (Float(i / 4) + 0.5) / 4) { n += 1 }
            return n
        }
    }

    /// One row of the ellipse: nothing outside `lo..<hi`, fully selected in `fullLo..<fullHi`.
    struct RowSpan: Sendable {
        var lo: Int32, fullLo: Int32, fullHi: Int32, hi: Int32
    }

    /// photocraft `row_span`: row `y` bounded from the exact (Double) ellipse with a margin for the
    /// Float tests' rounding, then verified with the exact tests (any doubt: the whole row).
    static func rowSpan(_ e: Ellipse, _ y: Int32, _ cut: PixelRect, _ aa: Bool) -> RowSpan {
        let exact = RowSpan(lo: cut.x0, fullLo: cut.x1, fullHi: cut.x1, hi: cut.x1)
        let cx = Double(e.cx), cy = Double(e.cy), rx = Double(e.rx), ry = Double(e.ry)
        let ya = Double(y), yb = Double(y) + 1
        let near = cy < ya ? ya - cy : max(cy - yb, 0)
        let far = max(abs(ya - cy), abs(yb - cy))
        func half(_ d: Double) -> Double {
            let t = 1 - (d / ry) * (d / ry)
            return t >= 0 ? rx * t.squareRoot() : -1
        }
        let outer = max(half(near), 0), inner = half(far)
        let m = 2 + rx * 1e-3
        if !(outer.isFinite && inner.isFinite && m.isFinite) { return exact }
        func px(_ v: Double) -> Int32 { Int32(min(max(v, Double(cut.x0)), Double(cut.x1))) }
        let lo = px((cx - outer - m).rounded(.down))
        let hi = px((cx + outer + m).rounded(.down) + 1)
        var fullLo = px((cx - inner + m).rounded(.up)), fullHi = px((cx + inner - m).rounded(.down))
        if inner < 0 || fullLo >= fullHi { (fullLo, fullHi) = (hi, hi) }
        func empty(_ x: Int32) -> Bool { e.coverage(x, y, aa) == 0 }
        let ok = (lo <= cut.x0 || empty(lo - 1)) && (hi >= cut.x1 || empty(hi))
            && (fullLo >= fullHi || (e.full(fullLo, y, aa) && e.full(fullHi - 1, y, aa)))
        return ok ? RowSpan(lo: lo, fullLo: fullLo, fullHi: fullHi, hi: hi) : exact
    }
}
