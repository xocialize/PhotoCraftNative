// Port of photocraft-algo (crates/algo/src/remove.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Remove Tool: fill what a brush stroke painted over from its surroundings. `closeLoops` (a
// stroke drawn around an object also removes what it encloses), `dilate` (the hole grows so an
// object's soft edge and halo go with it), `holeRadius` (how thick a hole is), and `removeWith`
// (the non-local completion; sparse holes tile by tile so the work follows the hole).

import PCFoundation

extension InpaintKit {
    /// `mask` plus everything it encloses: the cells from which no path of unmasked cells
    /// (4-connected) reaches the grid's border (photocraft `close_loops`). A mask of the wrong
    /// length comes back unchanged.
    public static func closeLoops(width w: Int, height h: Int, mask: [Bool]) -> [Bool] {
        if w == 0 || h == 0 || mask.count != w * h { return mask }
        var outside = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        func visit(_ i: Int) { if !mask[i] && !outside[i] { outside[i] = true; stack.append(i) } }
        for x in 0..<w { visit(x); visit((h - 1) * w + x) }
        for y in 0..<h { visit(y * w); visit(y * w + w - 1) }
        while let i = stack.popLast() {
            let (x, y) = (i % w, i / w)
            if x > 0 { visit(i - 1) }
            if x + 1 < w { visit(i + 1) }
            if y > 0 { visit(i - w) }
            if y + 1 < h { visit(i + w) }
        }
        return outside.map { !$0 }
    }

    /// `mask` grown by `r` cells (a square structuring element), in two separable passes
    /// (photocraft `dilate`).
    public static func dilate(width w: Int, height h: Int, mask: [Bool], radius r: Int) -> [Bool] {
        if r == 0 || mask.count != w * h { return mask }
        func pass(_ src: [Bool], _ horizontal: Bool) -> [Bool] {
            let (lines, len) = horizontal ? (h, w) : (w, h)
            @inline(__always) func at(_ line: Int, _ k: Int) -> Int { horizontal ? line * w + k : k * w + line }
            var out = [Bool](repeating: false, count: src.count)
            for line in 0..<lines {
                var count = 0
                for k in 0..<min(len, r) where src[at(line, k)] { count += 1 }
                for k in 0..<len {
                    if k + r < len && src[at(line, k + r)] { count += 1 }
                    if k > r && src[at(line, k - r - 1)] { count -= 1 }
                    out[at(line, k)] = count > 0
                }
            }
            return out
        }
        return pass(pass(mask, true), false)
    }

    /// The largest chessboard distance from a hole cell to the nearest cell outside the hole (cells
    /// beyond the grid don't count). `UInt32.max` when no cell lies outside the hole, 0 for a mask
    /// of the wrong size (photocraft `hole_radius`).
    public static func holeRadius(width w: Int, height h: Int, hole: [Bool]) -> UInt32 {
        if hole.count != w * h { return 0 }
        var d = hole.map { $0 ? UInt32.max : 0 }
        @inline(__always) func relax(_ i: Int, _ j: Int) {
            let v = d[j] == .max ? .max : d[j] + 1
            if v < d[i] { d[i] = v }
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if x > 0 { relax(i, i - 1) }
                if y > 0 {
                    relax(i, i - w)
                    if x > 0 { relax(i, i - w - 1) }
                    if x + 1 < w { relax(i, i - w + 1) }
                }
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                let i = y * w + x
                if x + 1 < w { relax(i, i + 1) }
                if y + 1 < h {
                    relax(i, i + w)
                    if x + 1 < w { relax(i, i + w + 1) }
                    if x > 0 { relax(i, i + w - 1) }
                }
            }
        }
        var best: UInt32 = 0
        for (v, m) in zip(d, hole) where m { best = max(best, v) }
        return best
    }

    /// Holes covering less than this share of their bounding box are completed tile by tile.
    static let sparse = 0.25
    /// Smallest tile side, in pixels.
    static let minTile = 256

    /// Fill `hole` in `img` from the pixels around it (photocraft `remove_with`). Returns the full
    /// buffer (unchanged outside the hole); a buffer or mask of the wrong size comes back
    /// unchanged. When nothing around the hole is fully known it is diffused from its edges. A
    /// sparse hole is filled in tiles eight times its thickness (at least 256 px), row by row, each
    /// with a margin of six times its thickness (at least 48 px).
    public static func removeWith(width w: Int, height h: Int, channels ch: Int, image img: [Float], hole: [Bool], seed: UInt64,
                                  interrupt ctl: Interrupt = .none) throws -> [Float] {
        let n = w * h
        if ch == 0 || hole.count != n || img.count != n * ch { return img }
        var (bx0, by0, bx1, by1, count) = (w, h, 0, 0, 0)
        for i in 0..<n where hole[i] {
            let (x, y) = (i % w, i / w)
            (bx0, by0, bx1, by1, count) = (min(bx0, x), min(by0, y), max(bx1, x + 1), max(by1, y + 1), count + 1)
        }
        if count == 0 { return img }
        let thickness = Int(min(holeRadius(width: w, height: h, hole: hole), 1 << 20))
        let tile = max(8 * thickness, minTile)
        let area = (bx1 - bx0) * (by1 - by0)
        if Double(count) >= sparse * Double(area) || max(bx1 - bx0, by1 - by0) <= 2 * tile {
            return try removeFill(w, h, ch, img, hole, seed, ctl)
        }
        let margin = max(6 * thickness, 48)
        var out = img
        var left = hole
        var origins: [(Int, Int)] = []
        for y in stride(from: by0, to: by1, by: tile) { for x in stride(from: bx0, to: bx1, by: tile) { origins.append((x, y)) } }
        for (k, (tx0, ty0)) in origins.enumerated() {
            try ctl.check()
            let (tx1, ty1) = (min(tx0 + tile, bx1), min(ty0 + tile, by1))
            var anyLeft = false
            for y in ty0..<ty1 where !anyLeft { for x in tx0..<tx1 where left[y * w + x] { anyLeft = true; break } }
            if !anyLeft { continue }
            let (x0, y0, x1, y1) = (max(tx0 - margin, 0), max(ty0 - margin, 0), min(tx1 + margin, w), min(ty1 + margin, h))
            let ww = x1 - x0
            var subImg: [Float] = []
            var subHole: [Bool] = []
            for y in y0..<y1 {
                subImg.append(contentsOf: out[((y * w + x0) * ch)..<((y * w + x1) * ch)])
                subHole.append(contentsOf: left[(y * w + x0)..<(y * w + x1)])
            }
            let total = Float(origins.count)
            let inner = Interrupt(cancel: ctl.cancel, progress: { [ctl] f in ctl.report((Float(k) + f) / total) })
            let filled = try removeFill(ww, y1 - y0, ch, subImg, subHole, seed &+ UInt64(k), inner)
            for y in ty0..<ty1 {
                for x in tx0..<tx1 where left[y * w + x] {
                    let i = y * w + x, j = (y - y0) * ww + (x - x0)
                    for c in 0..<ch { out[i * ch + c] = filled[j * ch + c] }
                    left[i] = false
                }
            }
        }
        return out
    }

    /// Complete one hole, or diffuse it when there is no fully-known patch to copy from.
    static func removeFill(_ w: Int, _ h: Int, _ ch: Int, _ img: [Float], _ hole: [Bool], _ seed: UInt64, _ ctl: Interrupt) throws -> [Float] {
        if let out = try nonLocalComplete(width: w, height: h, channels: ch, image: img, hole: hole, params: NonLocalParams(seed: seed), interrupt: ctl) {
            return out
        }
        let m = Poisson.membraneFill(width: w, height: h, channels: ch, image: img, hole: hole)
        try ctl.check()
        return m
    }
}
