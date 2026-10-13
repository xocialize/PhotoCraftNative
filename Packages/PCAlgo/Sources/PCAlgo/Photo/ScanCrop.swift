// Port of photocraft-algo (crates/algo/src/scancrop.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// File › Automate › Crop and Straighten Photos: find the photos on a flatbed scan, measure each
// one's rotation, and cut them out upright. Background = the per-channel median of the border;
// foreground = colour distance above an Otsu threshold (N. Otsu, IEEE SMC 1979) on a ≤ 800 px
// copy, closed and opened, split into 8-connected components; each component's rotation is its
// convex hull's minimum-area rectangle (Freeman & Shapira, CACM 1975), shrunk by a pixel. CPU
// only: a downsampled scan, a histogram and a few small sequential passes.

import Foundation
import PCFoundation

/// Crop and Straighten Photos detection (photocraft `scancrop`).
public enum ScanCrop {
    /// A found photo: centre, size along its own axes and the rotation that makes it upright.
    public struct FoundPhoto: Hashable, Sendable, Codable {
        public var center: SIMD2<Double>
        public var width: Double
        public var height: Double
        /// Angle of the photo's x axis in the scan (degrees, −45…45).
        public var angle: Double
        /// Area as a fraction of the scan.
        public var area: Double

        public init(center: SIMD2<Double>, width: Double, height: Double, angle: Double, area: Double) {
            self.center = center; self.width = width; self.height = height; self.angle = angle; self.area = area
        }

        /// The four corners in the scan, clockwise from the photo's top-left.
        public func corners() -> [SIMD2<Double>] {
            let a = PhotoKit.radians(angle)
            let s = sin(a), c = cos(a)
            let hw = width / 2, hh = height / 2
            return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { x, y in SIMD2(center.x + c * x - s * y, center.y + s * x + c * y) }
        }
    }

    static func otsu(_ v: [Float]) -> Float {
        let bins = 256
        var hist = [Double](repeating: 0, count: bins)
        for x in v { hist[PhotoKit.usize(PhotoKit.clamp01(x) * Float(bins - 1))] += 1 }
        var total = -0.0, sum = -0.0
        for h in hist { total += h }
        for (i, h) in hist.enumerated() { sum += Double(i) * h }
        var wb = 0.0, sb = 0.0, best = 0.0, thr = 0
        for (i, h) in hist.enumerated() {
            wb += h
            if wb == 0 { continue }
            let wf = total - wb
            if wf == 0 { break }
            sb += Double(i) * h
            let mb = sb / wb, mf = (sum - sb) / wf
            let between = wb * wf * (mb - mf) * (mb - mf)
            if between > best { best = between; thr = i }
        }
        return (Float(thr) + 0.5) / Float(bins - 1)
    }

    /// Separable square dilation (`dilate`) or erosion; outside the image reads false.
    static func morph(_ w: Int, _ h: Int, _ m: [Bool], _ r: Int, _ dilate: Bool) -> [Bool] {
        func pass(_ src: [Bool], _ horizontal: Bool) -> [Bool] {
            var out = [Bool](repeating: false, count: w * h)
            src.withUnsafeBufferPointer { s in
                out.withUnsafeMutableBufferPointer { o in
                    let sp = UnsafeSendable(s.baseAddress!), op = UnsafeSendable(o.baseAddress!)
                    PhotoKit.parRows(h) { y in
                        for x in 0..<w {
                            var acc = !dilate
                            for d in -r...r {
                                let xx = horizontal ? x + d : x, yy = horizontal ? y : y + d
                                let v = xx < 0 || yy < 0 || xx >= w || yy >= h ? false : sp.value[yy * w + xx]
                                if dilate { acc = acc || v } else { acc = acc && v }
                            }
                            op.value[y * w + x] = acc
                        }
                    }
                }
            }
            return out
        }
        if w == 0 || h == 0 { return m }
        return pass(pass(m, true), false)
    }

    /// Monotone-chain convex hull.
    static func convexHull(_ pts0: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var pts = pts0.sorted { a, b in
            if PhotoKit.totalLess(a.x, b.x) { return true }
            if PhotoKit.totalLess(b.x, a.x) { return false }
            return PhotoKit.totalLess(a.y, b.y)
        }
        // Rust `dedup`: drop consecutive duplicates.
        var d: [SIMD2<Double>] = []
        for p in pts where d.last != p { d.append(p) }
        pts = d
        if pts.count < 3 { return pts }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [SIMD2<Double>] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [SIMD2<Double>] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// Minimum-area rectangle around a convex hull: (centre, width, height, angle in degrees).
    static func minRect(_ hull: [SIMD2<Double>]) -> (SIMD2<Double>, Double, Double, Double) {
        var best = (Double.greatestFiniteMagnitude, SIMD2<Double>(0, 0), 0.0, 0.0, 0.0)
        let n = hull.count
        for i in 0..<n {
            let a = hull[i], b = hull[(i + 1) % n]
            let th = atan2(b.y - a.y, b.x - a.x)
            let s = sin(th), c = cos(th)
            var x0 = Double.greatestFiniteMagnitude, y0 = Double.greatestFiniteMagnitude, x1 = -Double.greatestFiniteMagnitude, y1 = -Double.greatestFiniteMagnitude
            for p in hull {
                let u = c * p.x + s * p.y, v = -s * p.x + c * p.y
                x0 = PhotoKit.dmin(x0, u); x1 = PhotoKit.dmax(x1, u)
                y0 = PhotoKit.dmin(y0, v); y1 = PhotoKit.dmax(y1, v)
            }
            let area = (x1 - x0) * (y1 - y0)
            if area < best.0 {
                let cu = (x0 + x1) / 2, cv = (y0 + y1) / 2
                best = (area, SIMD2(c * cu - s * cv, s * cu + c * cv), x1 - x0, y1 - y0, PhotoKit.degrees(th))
            }
        }
        var (center, w, h, ang) = (best.1, best.2, best.3, best.4)
        // Normalise to −45…45, swapping the sides when turning by 90°.
        while ang > 45 { ang -= 90; swap(&w, &h) }
        while ang < -45 { ang += 90; swap(&w, &h) }
        return (center, w, h, ang)
    }

    /// Finds the photos on a scan given as straight RGBA pixels (`w × h`), in reading order (top
    /// to bottom, then left to right) (photocraft `find_photos`).
    public static func findPhotos(width w: Int, height h: Int, rgba: [SIMD4<Float>]) -> [FoundPhoto] {
        if w < 8 || h < 8 { return [] }
        // Work on ≤ 800 px.
        let k = max((max(w, h) + 799) / 800, 1)
        let sw = (w + k - 1) / k, sh = (h + k - 1) / k
        var small = [SIMD3<Float>](repeating: .zero, count: sw * sh)
        var cnt = [UInt32](repeating: 0, count: sw * sh)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y / k) * sw + x / k
                let p = rgba[y * w + x]
                small[i].x += p.x; small[i].y += p.y; small[i].z += p.z
                cnt[i] += 1
            }
        }
        for i in 0..<small.count {
            let c = Float(max(cnt[i], 1))
            small[i].x /= c; small[i].y /= c; small[i].z /= c
        }
        // Background = per-channel median of the border.
        var border: [SIMD3<Float>] = []
        for x in 0..<sw { border.append(small[x]); border.append(small[(sh - 1) * sw + x]) }
        for y in 0..<sh { border.append(small[y * sw]); border.append(small[y * sw + sw - 1]) }
        let bg: [Float] = (0..<3).map { c in
            let v = PhotoKit.stableOrder(border.count) { PhotoKit.totalLess(border[$0][c], border[$1][c]) }.map { border[$0][c] }
            return v[v.count / 2]
        }
        let root3 = Float(3).squareRoot()
        let dist: [Float] = small.map { p in
            let a = p.x - bg[0], b = p.y - bg[1], c = p.z - bg[2]
            return (a * a + b * b + c * c).squareRoot() / root3
        }
        let thr = PhotoKit.fmax(otsu(dist), 0.04)
        var mask = dist.map { $0 > thr }
        let r = max(max(sw, sh) / 200, 1)
        mask = morph(sw, sh, morph(sw, sh, mask, r, true), r, false)
        mask = morph(sw, sh, morph(sw, sh, mask, 1, false), 1, true)
        // Connected components (8-connected).
        var label = [UInt32](repeating: .max, count: sw * sh)
        var comps: [[Int]] = []
        for s in 0..<(sw * sh) where mask[s] && label[s] == .max {
            let id = UInt32(comps.count)
            var stack = [s]
            label[s] = id
            var px: [Int] = []
            while let i = stack.popLast() {
                px.append(i)
                let x = i % sw, y = i / sw
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx, yy = y + dy
                        if xx < 0 || yy < 0 || xx >= sw || yy >= sh { continue }
                        let j = yy * sw + xx
                        if mask[j] && label[j] == .max { label[j] = id; stack.append(j) }
                    }
                }
            }
            comps.append(px)
        }
        let total = Double(sw * sh)
        var out: [FoundPhoto] = comps.filter { Double($0.count) > total * 0.01 }.map { c in
            // Hull of the boundary pixels' corners (in full-resolution px).
            var pts: [SIMD2<Double>] = []
            for i in c {
                let x = i % sw, y = i / sw
                let boundary = x == 0 || y == 0 || x + 1 == sw || y + 1 == sh || !mask[i - 1] || !mask[i + 1] || !mask[i - sw] || !mask[i + sw]
                if !boundary { continue }
                let xf = Double(x), yf = Double(y)
                for q in [SIMD2(xf, yf), SIMD2(xf + 1, yf), SIMD2(xf, yf + 1), SIMD2(xf + 1, yf + 1)] {
                    pts.append(SIMD2(q.x * Double(k), q.y * Double(k)))
                }
            }
            let hull = convexHull(pts)
            let (center, wd, ht, ang) = minRect(hull)
            let inset = Double(k)
            return FoundPhoto(center: center, width: PhotoKit.dmax(wd - 2 * inset, 1), height: PhotoKit.dmax(ht - 2 * inset, 1), angle: ang,
                              area: Double(c.count) / total)
        }
        // Reading order: rows by centre y (bands of a third of the smallest photo), then x.
        let band = PhotoKit.dmax(out.map { PhotoKit.dmin($0.height, $0.width) }.reduce(Double.greatestFiniteMagnitude) { PhotoKit.dmin($0, $1) }, 1) / 3
        let order = PhotoKit.stableOrder(out.count) { a, b in
            let ra = (out[a].center.y / band).rounded(.down), rb = (out[b].center.y / band).rounded(.down)
            if PhotoKit.totalLess(ra, rb) { return true }
            if PhotoKit.totalLess(rb, ra) { return false }
            return PhotoKit.totalLess(out[a].center.x, out[b].center.x)
        }
        out = order.map { out[$0] }
        return out
    }
}
