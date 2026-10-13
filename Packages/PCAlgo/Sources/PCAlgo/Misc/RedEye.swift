// Port of photocraft-algo (crates/algo/src/redeye.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Click-local red-eye correction: neutralise a red pupil around a click. The kernel never scans a
// full document: callers pass the search window plus a read halo covering a 1 px erosion and a
// Gaussian of σ 0.8. CPU only: the window is at most 512² and the pupil is found by a flood fill
// from the nearest red pixel (sequential), so a GPU round trip would cost more than the work.

import Foundation

public enum RedEye {
    /// Gaussian σ applied to the pupil mask after a 1 px shrink.
    public static let sigma: Float = 0.8
    /// Largest window (search + halo) the engine may allocate, in pixels on a side.
    public static let maxWindow: UInt32 = 512
    /// Clicks one command may apply in a single history step.
    public static let maxPoints = 64

    /// How far outside the search window the mask filter reads: erode (1) + ⌈3σ⌉ + margin (1).
    public static func haloRadius() -> Int32 {
        let b = (sigma * 3).rounded(.up)
        return 1 + (b.isFinite ? Int32(clampf(b, 0, 64)) : 3) + 1
    }

    /// Search radius in document pixels for a Pupil Size in 1…100.
    public static func searchRadius(_ pupilSize: Float) -> Float {
        let p = pupilSize.isFinite ? clampf(pupilSize, 1, 100) : 50
        return clampf(4 + 1.20 * p, 8, 128)
    }

    /// Side of the read rect (search + halo) before clamping Pupil Size; nil when non-finite or
    /// larger than `maxWindow`.
    public static func unclampedWindowSide(_ pupilSize: Float) -> UInt32? {
        if !pupilSize.isFinite { return nil }
        let r = 4 + 1.20 * pupilSize
        if !r.isFinite { return nil }
        let half = abs(r) + Float(haloRadius())
        if !half.isFinite || half > Float(maxWindow) { return nil }
        let side = (2 * half + 1).rounded(.up)
        if !side.isFinite || side > Float(maxWindow) { return nil }
        return UInt32(side)
    }

    static func luma(_ p: SIMD4<Float>) -> Float { 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z }

    static func isRedEye(_ p: SIMD4<Float>) -> Bool {
        let r = p.x, g = p.y, b = p.z
        if !(r.isFinite && g.isFinite && b.isFinite) { return false }
        if r <= g + 0.15 || r <= b + 0.15 { return false }
        if luma(p) >= 0.92 { return false }
        return max(r, g, b) - min(r, g, b) >= 0.08
    }

    static func withinSearch(_ dx: Int32, _ dy: Int32, _ radius: Float) -> Bool {
        let d = hypotf(Float(dx), Float(dy))
        return d.isFinite && d <= radius
    }

    static func blur(_ src: [Float], _ w: Int, _ h: Int, _ sigma: Float) -> [Float] {
        let n = w * h
        if w == 0 || h == 0 || src.count < n { return [Float](repeating: 0, count: n) }
        if !sigma.isFinite || sigma < 0.1 { return Array(src[0..<n]) }
        let rr = (sigma * 3).rounded(.up)
        let r = rr.isFinite ? Int(clampf(rr, 1, 32)) : 3
        var k: [Float] = []
        var sum: Float = 0
        for i in -r...r {
            let wgt = expf(-Float(i * i) / (2 * sigma * sigma))
            if !wgt.isFinite { continue }
            k.append(wgt); sum += wgt
        }
        if k.isEmpty || !sum.isFinite || sum <= 0 { return Array(src[0..<n]) }
        k = k.map { $0 / sum }
        var tmp = [Float](repeating: 0, count: n), out = [Float](repeating: 0, count: n)
        for y in 0..<h {
            for x in 0..<w {
                var a: Float = 0
                for (ki, wgt) in k.enumerated() { a += src[y * w + min(max(x + ki - r, 0), w - 1)] * wgt }
                tmp[y * w + x] = a
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var a: Float = 0
                for (ki, wgt) in k.enumerated() { a += tmp[min(max(y + ki - r, 0), h - 1) * w + x] * wgt }
                out[y * w + x] = a
            }
        }
        return out
    }

    /// Corrects red-eye in `px` (row-major straight RGBA including the `haloRadius` border); `origin`
    /// is the document coordinate of `px[0]`. Returns how many pixels changed (photocraft `apply`).
    @discardableResult
    public static func apply(_ px: inout [SIMD4<Float>], width w: Int, height h: Int, click: (Int32, Int32), origin: (Int32, Int32),
                             pupilSize: Float, darken: Float) -> UInt32 {
        let n = w * h
        if w == 0 || h == 0 || px.count < n { return 0 }
        let radius = searchRadius(pupilSize)
        let tAmt = darken.isFinite ? clampf(clampf(darken, 0, 100) / 100, 0, 1) : 0.5
        func d(_ x: Int, _ y: Int) -> (Int32, Int32) { (origin.0 &+ Int32(x) &- click.0, origin.1 &+ Int32(y) &- click.1) }
        var hard = [Bool](repeating: false, count: n)
        for y in 0..<h { for x in 0..<w {
            let (dx, dy) = d(x, y)
            if withinSearch(dx, dy, radius) && isRedEye(px[y * w + x]) { hard[y * w + x] = true }
        } }
        // Nearest seed (the first of equals in raster order).
        var best: (Int, Int64)? = nil
        for y in 0..<h { for x in 0..<w where hard[y * w + x] {
            let (dx, dy) = d(x, y)
            if !withinSearch(dx, dy, radius) { continue }
            let d2 = Int64(dx) * Int64(dx) + Int64(dy) * Int64(dy)
            if let b = best, d2 >= b.1 { continue }
            best = (y * w + x, d2)
        } }
        guard let seed = best?.0 else { return 0 }
        // Flood keep (4-connected, stack order as photocraft).
        var keep = [Bool](repeating: false, count: n)
        var stack = [seed]
        while let i = stack.popLast() {
            if keep[i] || !hard[i] { continue }
            keep[i] = true
            let x = i % w, y = i / w
            if x > 0 { stack.append(i - 1) }
            if x + 1 < w { stack.append(i + 1) }
            if y > 0 { stack.append(i - w) }
            if y + 1 < h { stack.append(i + w) }
            if stack.count > n * 4 { break }
        }
        hard = keep
        // Erode (3×3, outside counts as off).
        var softIn = [Float](repeating: 0, count: n)
        for y in 0..<h { for x in 0..<w {
            var on = true
            for dy in -1...1 { for dx in -1...1 {
                let xx = x + dx, yy = y + dy
                if xx < 0 || yy < 0 || xx >= w || yy >= h || !hard[yy * w + xx] { on = false }
            } }
            softIn[y * w + x] = on ? 1 : 0
        } }
        let soft = blur(softIn, w, h, sigma)
        var changed: UInt32 = 0
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            let (dx, dy) = d(x, y)
            if !withinSearch(dx, dy, radius) { continue }
            let p = px[i]
            if luma(p) >= 0.92 { continue }
            let t = clampf(soft[i], 0, 1) * tAmt
            if t <= 1e-4 { continue }
            let neut = (p.y + p.z) * 0.5
            let r1 = p.x + (neut - p.x) * t
            let scale = 1 - 0.45 * t
            let r2 = r1 * scale, g2 = p.y * scale, b2 = p.z * scale
            if !(r2.isFinite && g2.isFinite && b2.isFinite) { continue }
            if abs(r2 - p.x) < 1e-6 && abs(g2 - p.y) < 1e-6 && abs(b2 - p.z) < 1e-6 { continue }
            px[i] = SIMD4(r2, g2, b2, p.w)
            changed &+= 1
        } }
        return changed
    }
}
