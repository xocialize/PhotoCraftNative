// Port of photocraft-algo (crates/algo/src/magnetic.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Magnetic Lasso edge tracing: between two fastening points the border is the cheapest
// 8-connected path where pixels on a strong, well-localised edge are cheap — the live wire of
// Mortensen & Barrett (SIGGRAPH 1995), with an edge-strength term, an edge-centre term
// (non-maximum suppression across the edge) and a gradient-direction term. The search stays in a
// corridor of the detection width around the pointer's path, with a small pull towards it; points
// on an edge land at its sub-pixel centre. Pixels are read lazily in 128 px blocks through a
// caller-supplied fetch, so tracing on a 36 MP image reads only the area around the border.
// CPU only: the per-trace field is a few blocks (an O(area) Sobel the CPU does in microseconds)
// and the search is a sequential Dijkstra.

import Foundation
import PCFoundation

/// Magnetic Lasso (photocraft `magnetic`).
public enum MagneticLasso {
    /// Side of the cached pixel blocks (px).
    static let block: Int32 = 128
    /// Blocks kept before the cache starts over.
    static let maxBlocks = 1024
    /// Longest stretch of the pointer's path searched at once (px).
    static let piece = 256.0
    /// Longest pointer path `trace` follows (px); a longer one is returned as is.
    public static let maxGuideLength = 262_144.0
    /// Detection width limits (px).
    public static let widthRange = (1.0, 256.0)
    static let wCentre: Float = 0.43, wStrength: Float = 0.43, wDirection: Float = 0.14, wLength: Float = 0.02, wGuide: Float = 0.4
    /// The direction term where either pixel has no edge direction.
    static let neutralDirection: Float = 2.0 / 3.0
    /// The 8 neighbours, in the order the search records them.
    static let dirs: [(Int, Int)] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]

    /// Detection settings: the options bar.
    public struct Settings: Sendable, Hashable {
        /// Detection width (px): the border follows only edges this close to the pointer's path.
        public var width: Double
        /// Contrast (0…1): steps weaker than this, in every channel, are not edges.
        public var contrast: Float

        public static let `default` = Settings(raw: 10, 0.1)
        init(raw width: Double, _ contrast: Float) { self.width = width; self.contrast = contrast }

        /// Settings clamped to their ranges (width 1…256 px, contrast 1…100 %); NaN takes the default.
        public init(width: Double, contrast: Float) {
            self.width = width.isFinite ? min(max(width, widthRange.0), widthRange.1) : Settings.default.width
            self.contrast = contrast.isFinite ? clampf(contrast, 0.01, 1) : Settings.default.contrast
        }

        var radius: Double { width + 1.5 }
    }

    /// Straight-alpha RGBA8 pixels of a rectangle inside the image, row-major (a result of the
    /// wrong length reads as transparent).
    public typealias Fetch = (PixelRect) -> [SIMD4<UInt8>]

    /// Edge tracing over one image, caching the pixels it has read.
    public struct Tracer {
        public let bounds: PixelRect
        var blocks: [SIMD2<Int32>: [SIMD4<UInt8>]] = [:]

        public init(bounds: PixelRect) { self.bounds = bounds }

        /// Pixels read so far.
        public var cachedPixels: Int { blocks.values.reduce(0) { $0 + $1.count } }

        /// Where a fastening point near `p` goes: the centre of the most prominent edge within the
        /// detection width, or `p` (kept inside the image) when none reaches the contrast; nil when
        /// `p` is not a finite point or the image is empty.
        public mutating func snap(_ fetch: Fetch, _ p0: SIMD2<Double>, _ s0: Settings) -> SIMD2<Double>? {
            let s = Settings(width: s0.width, contrast: s0.contrast)
            guard let p = clampPoint(p0) else { return nil }
            let r = s.width
            let (px, py) = pixel(p)
            let ri = Int32(r.rounded(.up)) + 1
            let area = PixelRect(x0: Int32(clamping: Int(px) - Int(ri)), y0: Int32(clamping: Int(py) - Int(ri)),
                                 x1: Int32(clamping: Int(px) + Int(ri) + 1), y1: Int32(clamping: Int(py) + Int(ri) + 1)).intersect(bounds)
            let f = field(fetch, area)
            var best: (Float, SIMD2<Double>)?
            for y in area.y0..<area.y1 {
                for x in area.x0..<area.x1 {
                    guard let i = f.index(x, y) else { continue }
                    let strength = f.strength[i]
                    if strength < s.contrast || !f.ridge[i] { continue }
                    let d = MagneticLasso.dist(SIMD2(Double(x) + 0.5, Double(y) + 0.5), p)
                    if d > r { continue }
                    // The strongest edge, a little in favour of the nearer one.
                    let score = strength * (1 - 0.25 * Float(d / r))
                    if best == nil || score > best!.0 { best = (score, f.point(i, x, y, s.contrast)) }
                }
            }
            return best?.1 ?? p
        }

        /// The border from `from` to `to` along the edges near `guide` (the pointer's path between
        /// them); starts at `from` and ends at `to` exactly (both kept inside the image). Empty when
        /// either is not a finite point or the image is empty.
        public mutating func trace(_ fetch: Fetch, from f0: SIMD2<Double>, to t0: SIMD2<Double>, guide: [SIMD2<Double>], _ s0: Settings) -> [SIMD2<Double>] {
            let s = Settings(width: s0.width, contrast: s0.contrast)
            guard let from = clampPoint(f0), let to = clampPoint(t0) else { return [] }
            var g = [from]
            g.append(contentsOf: guide.compactMap { clampPoint($0) })
            g.append(to)
            // A coarse guide is enough for the corridor, and much cheaper to draw.
            g = MagneticLasso.simplify(g, 0.5)
            if MagneticLasso.length(g) > maxGuideLength { return g }
            let pieces = MagneticLasso.split(g, piece)
            var out = [from]
            var cur = from
            let last = max(pieces.count - 1, 0)
            for (k, pc) in pieces.enumerated() {
                let target = k == last ? to : (pc.last.flatMap { snap(fetch, $0, s) } ?? to)
                out.append(contentsOf: tracePiece(fetch, cur, target, pc, s).dropFirst())
                cur = target
            }
            // Within half a pixel: drops the staircase of pixel steps, keeps the curve of an edge.
            return MagneticLasso.simplify(out, 0.5)
        }

        /// One piece: the cheapest path from `a` to `b` in the corridor around `guide`.
        mutating func tracePiece(_ fetch: Fetch, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ guide: [SIMD2<Double>], _ s: Settings) -> [SIMD2<Double>] {
            let rad = s.radius
            let (ax, ay) = pixel(a), (bx, by) = pixel(b)
            var bbox = PixelRect(x0: min(ax, bx), y0: min(ay, by), x1: max(ax, bx) + 1, y1: max(ay, by) + 1)
            for q in guide {
                let (x, y) = pixel(q)
                bbox = bbox.union(PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1))
            }
            let area = bbox.outset(by: Int32(rad.rounded(.up)) + 1).intersect(bounds)
            let f = field(fetch, area)
            var near = MagneticLasso.corridor(area, guide, rad)
            guard let start = f.index(ax, ay), let goal = f.index(bx, by) else { return [a, b] }
            near[start] = 0
            near[goal] = 0
            guard let cells = MagneticLasso.search(f, near, Float(rad * rad), start, goal, s.contrast) else { return [a, b] }
            var pts = cells.map { f.pointAt($0, s.contrast) }
            if pts.count < 2 { return [a, b] }
            pts[0] = a
            pts[pts.count - 1] = b
            return pts
        }

        /// `p` kept inside the image, or nil if not finite or the image is empty.
        func clampPoint(_ p: SIMD2<Double>) -> SIMD2<Double>? {
            let b = bounds
            if b.isEmpty || !p.x.isFinite || !p.y.isFinite { return nil }
            return SIMD2(min(max(p.x, Double(b.x0)), Double(b.x1)), min(max(p.y, Double(b.y0)), Double(b.y1)))
        }

        /// The pixel under a point (clamped to the image).
        func pixel(_ p: SIMD2<Double>) -> (Int32, Int32) {
            let b = bounds
            func c(_ v: Double, _ lo: Int32, _ hi: Int32) -> Int32 {
                guard v.isFinite else { return lo }
                let f = v.rounded(.down)
                let i: Int32 = f >= 2147483647 ? .max : (f <= -2147483648 ? .min : Int32(f))
                return min(max(i, lo), max(hi - 1, lo))
            }
            return (c(p.x, b.x0, b.x1), c(p.y, b.y0, b.y1))
        }

        /// Edge features over `area` (inside the image).
        mutating func field(_ fetch: Fetch, _ area: PixelRect) -> Field {
            // Sobel reads one ring beyond the gradient, non-maximum suppression one beyond the area.
            let ext = area.outset(by: 2).intersect(bounds)
            return Field(area, ext, pixels(fetch, ext))
        }

        /// Straight RGBA8 pixels of `r` (inside the image), through the block cache.
        mutating func pixels(_ fetch: Fetch, _ r: PixelRect) -> [SIMD4<UInt8>] {
            let w = r.width
            var out = [SIMD4<UInt8>](repeating: .zero, count: w * r.height)
            if r.isEmpty { return out }
            if blocks.count > maxBlocks { blocks.removeAll() }
            func divE(_ a: Int32, _ b: Int32) -> Int32 { Int32((Int(a) - (a < 0 ? Int(b) - 1 : 0)) / Int(b)) }
            func satMul(_ a: Int32) -> Int32 { Int32(clamping: Int(a) * Int(block)) }
            let bx0 = divE(r.x0, block), by0 = divE(r.y0, block), bx1 = divE(r.x1 - 1, block), by1 = divE(r.y1 - 1, block)
            for by in by0...by1 {
                for bx in bx0...bx1 {
                    let br = PixelRect(x0: satMul(bx), y0: satMul(by), x1: satMul(bx &+ 1), y1: satMul(by &+ 1)).intersect(bounds)
                    if br.isEmpty { continue }
                    let n = br.area
                    let key = SIMD2(bx, by)
                    if blocks[key] == nil {
                        let v = fetch(br)
                        blocks[key] = v.count == n ? v : [SIMD4<UInt8>](repeating: .zero, count: n)
                    }
                    let blk = blocks[key]!
                    let ov = br.intersect(r)
                    let len = ov.width
                    for y in ov.y0..<ov.y1 {
                        let src = Int(y - br.y0) * br.width + Int(ov.x0 - br.x0)
                        let dst = Int(y - r.y0) * w + Int(ov.x0 - r.x0)
                        out.replaceSubrange(dst..<(dst + len), with: blk[src..<(src + len)])
                    }
                }
            }
            return out
        }
    }

    /// Edge features of the pixels in an area.
    struct Field {
        let area: PixelRect
        let w: Int
        /// The steepest channel's Sobel gradient, scaled so a sharp step of height h reads h (≤ 1).
        var strength: [Float]
        /// Unit gradient of that channel (zero on flat pixels).
        var grad: [SIMD2<Float>]
        /// The pixel is the strongest across its edge (non-maximum suppression).
        var ridge: [Bool]
        /// From the pixel centre to the edge's sub-pixel centre, along the gradient.
        var offset: [SIMD2<Float>]

        /// Features over `area` from the straight RGBA8 pixels `px` of `ext` (the area plus up to two
        /// pixels around it; beyond it the edge pixels repeat).
        init(_ area: PixelRect, _ ext: PixelRect, _ px: [SIMD4<UInt8>]) {
            let ew = ext.width, eh = ext.height
            // Premultiplied channels: an opaque shape on transparency has an edge.
            let ch: [SIMD4<Float>] = px.map { p in
                let a = Float(p.w) / 255
                return SIMD4(Float(p.x) / 255 * a, Float(p.y) / 255 * a, Float(p.z) / 255 * a, a)
            }
            func at(_ x: Int32, _ y: Int32) -> SIMD4<Float> {
                let xx = min(max(Int(x - ext.x0), 0), max(ew - 1, 0)), yy = min(max(Int(y - ext.y0), 0), max(eh - 1, 0))
                let i = yy * max(ew, 0) + xx
                return i < ch.count ? ch[i] : .zero
            }
            // Gradients over the area plus one ring.
            let g1 = area.outset(by: 1).intersect(ext)
            let gw = g1.width
            var st = [Float](repeating: 0, count: gw * g1.height)
            var gd = [SIMD2<Float>](repeating: .zero, count: st.count)
            if !g1.isEmpty {
                for y in g1.y0..<g1.y1 {
                    for x in g1.x0..<g1.x1 {
                        let nw = at(x - 1, y - 1), n = at(x, y - 1), ne = at(x + 1, y - 1)
                        let we = at(x - 1, y), e = at(x + 1, y)
                        let sw = at(x - 1, y + 1), s = at(x, y + 1), se = at(x + 1, y + 1)
                        var best: (Float, SIMD2<Float>) = (0, .zero)
                        for c in 0..<4 {
                            let gx = (ne[c] + 2 * e[c] + se[c]) - (nw[c] + 2 * we[c] + sw[c])
                            let gy = (sw[c] + 2 * s[c] + se[c]) - (nw[c] + 2 * n[c] + ne[c])
                            let m2 = gx * gx + gy * gy
                            if m2 > best.0 { best = (m2, SIMD2(gx, gy)) }
                        }
                        let mag = best.0.squareRoot()
                        let i = Int(y - g1.y0) * gw + Int(x - g1.x0)
                        st[i] = Float.minimum(mag / 4, 1)
                        gd[i] = mag > 1e-6 ? SIMD2(best.1.x / mag, best.1.y / mag) : .zero
                    }
                }
            }
            func sAt(_ x: Int32, _ y: Int32) -> Float { g1.contains(x: x, y: y) ? st[Int(y - g1.y0) * gw + Int(x - g1.x0)] : 0 }
            self.area = area
            w = area.width
            let n = w * area.height
            strength = [Float](repeating: 0, count: n)
            grad = [SIMD2<Float>](repeating: .zero, count: n)
            ridge = [Bool](repeating: false, count: n)
            offset = [SIMD2<Float>](repeating: .zero, count: n)
            if area.isEmpty { return }
            for y in area.y0..<area.y1 {
                for x in area.x0..<area.x1 {
                    let s0 = sAt(x, y)
                    let g = g1.contains(x: x, y: y) ? gd[Int(y - g1.y0) * gw + Int(x - g1.x0)] : .zero
                    let i = Int(y - area.y0) * w + Int(x - area.x0)
                    strength[i] = s0
                    grad[i] = g
                    if g == .zero { continue }
                    // The neighbours across the edge: the gradient rounded to one of 8 directions.
                    func q(_ v: Float, _ o: Float) -> Int32 { abs(v) >= 0.4142 * abs(o) ? (v.isNaN ? 0 : (v.sign == .minus ? -1 : 1)) : 0 }
                    let dx = q(g.x, g.y), dy = q(g.y, g.x)
                    let sm = sAt(x - dx, y - dy), sp = sAt(x + dx, y + dy)
                    if s0 > 0 && s0 >= sm && s0 >= sp {
                        ridge[i] = true
                        // The peak of the parabola through the three strengths.
                        let denom = sm - 2 * s0 + sp
                        let t: Float = denom < -1e-6 ? clampf(0.5 * (sm - sp) / denom, -0.5, 0.5) : 0
                        offset[i] = SIMD2(t * Float(dx), t * Float(dy))
                    }
                }
            }
        }

        var h: Int { strength.count / max(w, 1) }

        func index(_ x: Int32, _ y: Int32) -> Int? { area.contains(x: x, y: y) ? Int(y - area.y0) * w + Int(x - area.x0) : nil }

        /// Where the border runs through pixel i at (x, y): the edge's sub-pixel centre on an edge at
        /// least `contrast` strong, else the pixel centre.
        func point(_ i: Int, _ x: Int32, _ y: Int32, _ contrast: Float) -> SIMD2<Double> {
            let onEdge = ridge[i] && strength[i] >= contrast
            let o = onEdge ? offset[i] : .zero
            return SIMD2(Double(x) + 0.5 + Double(o.x), Double(y) + 0.5 + Double(o.y))
        }

        func pointAt(_ i: Int, _ contrast: Float) -> SIMD2<Double> {
            let ww = max(w, 1)
            return point(i, Int32(i % ww) + area.x0, Int32(i / ww) + area.y0, contrast)
        }
    }

    /// Squared distance from each pixel centre of `area` to the polyline `guide`, infinite beyond
    /// `rad`: the corridor the border may use.
    static func corridor(_ area: PixelRect, _ guide: [SIMD2<Double>], _ rad: Double) -> [Float] {
        let w = area.width
        var near = [Float](repeating: .infinity, count: w * area.height)
        let r2 = rad * rad
        let segs = guide.count == 1 ? [guide[0], guide[0]] : guide
        if segs.count < 2 { return near }
        for k in 1..<segs.count {
            let a = segs[k - 1], b = segs[k]
            func lo(_ u: Double, _ v: Double) -> Int32 { satI32((min(u, v) - rad).rounded(.down)) }
            func hi(_ u: Double, _ v: Double) -> Int32 { satI32((max(u, v) + rad).rounded(.up)) &+ 1 }
            let r = PixelRect(x0: lo(a.x, b.x), y0: lo(a.y, b.y), x1: hi(a.x, b.x), y1: hi(a.y, b.y)).intersect(area)
            if r.isEmpty { continue }
            for y in r.y0..<r.y1 {
                for x in r.x0..<r.x1 {
                    let d2 = dist2Segment(SIMD2(Double(x) + 0.5, Double(y) + 0.5), a, b)
                    if d2 <= r2 {
                        let i = Int(y - area.y0) * w + Int(x - area.x0)
                        near[i] = Float.minimum(near[i], Float(d2))
                    }
                }
            }
        }
        return near
    }

    static func satI32(_ v: Double) -> Int32 { v.isNaN ? 0 : (v >= 2147483647 ? .max : (v <= -2147483648 ? .min : Int32(v))) }

    /// A min-heap of (cost bits, index) in lexicographic order (Rust's `BinaryHeap<Reverse<…>>`).
    struct Heap {
        var items: [(UInt32, Int)] = []
        @inline(__always) static func less(_ a: (UInt32, Int), _ b: (UInt32, Int)) -> Bool { a.0 < b.0 || (a.0 == b.0 && a.1 < b.1) }
        mutating func push(_ e: (UInt32, Int)) {
            items.append(e)
            var i = items.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if !Heap.less(items[i], items[p]) { break }
                items.swapAt(i, p)
                i = p
            }
        }
        mutating func pop() -> (UInt32, Int)? {
            guard !items.isEmpty else { return nil }
            items.swapAt(0, items.count - 1)
            let top = items.removeLast()
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && Heap.less(items[l], items[m]) { m = l }
                if r < items.count && Heap.less(items[r], items[m]) { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
            return top
        }
    }

    /// The cheapest 8-connected path from `start` to `goal` through the corridor (photocraft `search`).
    static func search(_ f: Field, _ near: [Float], _ rad2: Float, _ start: Int, _ goal: Int, _ contrast: Float) -> [Int]? {
        let w = f.w, h = f.h, n = w * h
        // Cost of entering each pixel, per pixel of length, and its edge tangent.
        var node = [Float](repeating: .infinity, count: n)
        var tangent = [SIMD2<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            let d2 = i < near.count ? near[i] : .infinity
            if !d2.isFinite { continue }
            let s = f.strength[i]
            let onEdge = s >= contrast && f.ridge[i]
            let good = clampf((s - contrast) / Float.maximum(contrast, 0.02), 0, 1) * (0.6 + 0.4 * Float.minimum(s, 1))
            let pull = Float.minimum((d2 / Float.maximum(rad2, 1)).squareRoot(), 1)
            let centre: Float = onEdge ? 0 : 1
            node[i] = wCentre * centre + wStrength * (1 - good) + wLength + wGuide * pull
            if s >= 0.5 * contrast { tangent[i] = SIMD2(f.grad[i].y, -f.grad[i].x) }
        }
        var dist = [Float](repeating: .infinity, count: n)
        var from = [UInt8](repeating: UInt8.max, count: n)
        if start >= n { return nil }
        dist[start] = 0
        var heap = Heap()
        heap.push((Float(0).bitPattern, start))
        while let (bits, i) = heap.pop() {
            let d = Float(bitPattern: bits)
            if d > dist[i] { continue }
            if i == goal { break }
            let x = i % w, y = i / w
            let tp = tangent[i]
            for (k, (dx, dy)) in dirs.enumerated() {
                let nx = x + dx, ny = y + dy
                if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                let j = ny * w + nx
                let cost = node[j]
                if !cost.isFinite { continue }
                let len: Float = dx != 0 && dy != 0 ? 1.41421356237309504880 : 1
                let nd = d + cost * len + wDirection * directionCost(tp, tangent[j], dx, dy, len)
                if nd < dist[j] {
                    dist[j] = nd
                    from[j] = UInt8(k)
                    heap.push((nd.bitPattern, j))
                }
            }
        }
        if goal >= n || !dist[goal].isFinite { return nil }
        var cells = [goal]
        var cur = goal
        while cur != start && cells.count <= n {
            let k = Int(from[cur])
            if k >= dirs.count { return nil }
            let (dx, dy) = dirs[k]
            let x = cur % w - dx, y = cur / w - dy
            if x < 0 || y < 0 { return nil }
            cur = y * w + x
            cells.append(cur)
        }
        return cells.reversed()
    }

    /// The gradient-direction term of a link (Mortensen & Barrett's f_D): 0 running straight along
    /// an edge, up to 1 cutting across it or turning sharply.
    static func directionCost(_ tp: SIMD2<Float>, _ tq: SIMD2<Float>, _ dx: Int, _ dy: Int, _ len: Float) -> Float {
        if tp == .zero || tq == .zero { return neutralDirection }
        var l = SIMD2(Float(dx) / len, Float(dy) / len)
        if tp.x * l.x + tp.y * l.y < 0 { l = -l }
        let dp = clampf(tp.x * l.x + tp.y * l.y, -1, 1)
        let dq = clampf(l.x * tq.x + l.y * tq.y, -1, 1)
        return 2 / (3 * PCAMath.pi) * (acosf(dp) + acosf(dq))
    }

    /// The polyline `g` cut into pieces at most `piece` long; each piece starts where the last ended.
    static func split(_ g: [SIMD2<Double>], _ piece: Double) -> [[SIMD2<Double>]] {
        guard let first = g.first else { return [] }
        var out: [[SIMD2<Double>]] = []
        var cur = [first]
        var acc = 0.0
        if g.count >= 2 {
            for k in 1..<g.count {
                var a = g[k - 1]
                let b = g[k]
                var seg = dist(a, b)
                while acc + seg > piece && seg > 0 {
                    let t = min(max((piece - acc) / seg, 0), 1)
                    let m = SIMD2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
                    cur.append(m)
                    out.append(cur)
                    cur = [m]
                    a = m
                    seg = dist(a, b)
                    acc = 0
                }
                cur.append(b)
                acc += seg
            }
        }
        out.append(cur)
        return out
    }

    /// Ramer–Douglas–Peucker: drops points within `tol` of the line through their neighbours that
    /// stay, keeping both ends.
    public static func simplify(_ p: [SIMD2<Double>], _ tol: Double) -> [SIMD2<Double>] {
        let n = p.count
        if n < 3 { return p }
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true
        keep[n - 1] = true
        let tol2 = tol * tol
        var stack = [(0, n - 1)]
        while let (a, b) = stack.popLast() {
            if b <= a + 1 { continue }
            var far = (0.0, a)
            for k in (a + 1)..<b {
                let d2 = dist2Segment(p[k], p[a], p[b])
                if d2 > far.0 { far = (d2, k) }
            }
            if far.0 > tol2 {
                keep[far.1] = true
                stack.append((a, far.1))
                stack.append((far.1, b))
            }
        }
        return zip(p, keep).filter { $0.1 }.map { $0.0 }
    }

    /// Length of a polyline.
    public static func length(_ p: [SIMD2<Double>]) -> Double {
        var s = 0.0
        if p.count >= 2 { for i in 1..<p.count { s += dist(p[i - 1], p[i]) } }
        return s
    }

    static func dist(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { hypot(a.x - b.x, a.y - b.y) }

    static func dist2Segment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let vx = b.x - a.x, vy = b.y - a.y
        let l2 = vx * vx + vy * vy
        let t = l2 > 0 ? min(max(((p.x - a.x) * vx + (p.y - a.y) * vy) / l2, 0), 1) : 0
        let dx = p.x - (a.x + t * vx), dy = p.y - (a.y + t * vy)
        return dx * dx + dy * dy
    }
}
