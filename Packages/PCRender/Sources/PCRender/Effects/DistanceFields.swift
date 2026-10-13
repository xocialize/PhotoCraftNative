// Port of photocraft-compose (crates/compose/src/effects.rs) and photocraft-gpu (fx.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Distance fields of an effect shape. Strokes and spread / choke measure distances with a 5 × 5
// chamfer metric seeded at sub-pixel edge offsets (as Photoshop does); precise glows use an exact
// Euclidean distance transform (Felzenszwalb & Huttenlocher, line by line in parallel); chiselled
// bevels refine the Euclidean field with the straight edge each sharp anti-aliased edge pixel puts
// through it. As in photocraft-gpu, the GPU compositor computes these fields with this same code on
// the CPU (bit for bit the reference's) and uploads them; every other map stage runs on the GPU.

import Foundation

/// A single-channel map over a rectangle (photocraft effects `Map`).
public struct FxMap: Sendable, Equatable {
    public var w: Int
    public var h: Int
    public var v: [Float]

    public init(w: Int, h: Int, fill: Float = 0) { self.w = w; self.h = h; v = [Float](repeating: fill, count: w * h) }
    public init(w: Int, h: Int, v: [Float]) { self.w = w; self.h = h; self.v = v }

    /// Value at (x, y), 0 outside.
    @inline(__always) func get(_ x: Int, _ y: Int) -> Float {
        (x < 0 || y < 0 || x >= w || y >= h) ? 0 : v[y * w + x]
    }

    /// Shifted copy (bilinear), outside reads `outside`.
    func shifted(_ dx: Float, _ dy: Float, outside: Float) -> FxMap {
        var out = FxMap(w: w, h: h)
        let (fx, fy) = (dx.rounded(.down), dy.rounded(.down))
        let (ax, ay) = (dx - fx, dy - fy)
        let (ix, iy) = (Int(fx), Int(fy))
        let (w, h) = (self.w, self.h)
        v.withUnsafeBufferPointer { src in
            out.v.withUnsafeMutableBufferPointer { dst in
                let s = UnsafeSendable(src), d = UnsafeSendable(dst)
                func at(_ x: Int, _ y: Int) -> Float { (x < 0 || y < 0 || x >= w || y >= h) ? outside : s.value[y * w + x] }
                parallelRows(h, width: w) { y in
                    for x in 0..<w {
                        let (sx, sy) = (x - ix, y - iy)
                        let top = at(sx, sy) * (1 - ax) + at(sx - 1, sy) * ax
                        let bot = at(sx, sy - 1) * (1 - ax) + at(sx - 1, sy - 1) * ax
                        d.value[y * w + x] = top * (1 - ay) + bot * ay
                    }
                }
            }
        }
        return out
    }

    func map(_ f: (Float) -> Float) -> FxMap {
        var out = self
        for i in out.v.indices { out.v[i] = f(out.v[i]) }
        return out
    }
}

/// Alpha above which a pixel belongs to the layer's shape (half an 8-bit step).
public let insideEps: Float = 0.5 / 255

/// Far outside any shape (distance fill for cropped distance fields).
let farDistance: Float = 1.0e9

/// A distance field of an effect shape (photocraft `FieldKind`).
public enum FieldKind: Int, Hashable, Sendable, CaseIterable {
    /// `dist_outside`: precise outer glows.
    case outside
    /// `dist_inside`: precise inner glows.
    case inside
    /// `bevel_dist_outside`: chiselled bevels.
    case bevelOutside
    /// `bevel_dist_inside`: chiselled bevels.
    case bevelInside
    /// Chamfer distance outside the shape: outside strokes, spread of shadows / softer glows.
    case strokeOutside
    /// Chamfer distance outside `1 − alpha`: choke of inner shadows / softer inner glows.
    case chokeInside
    /// Chamfer distance inside the shape (inside strokes).
    case strokeInside
    /// Chamfer distance outside a shape layer's outline (from its local coverage).
    case strokeOutsideVector
}

public enum DistanceFields {
    static let chamferInf: Float = 1e20

    /// The `kind` field of the shape `alpha` (row-major `w × h`); values past `reach` are only large.
    public static func field(_ kind: FieldKind, alpha: [Float], w: Int, h: Int, reach: Float) -> [Float] {
        let s = FxMap(w: w, h: h, v: alpha)
        switch kind {
        case .outside: return distOutside(s, .euclidean)
        case .inside: return distInside(s, .euclidean)
        case .bevelOutside: return bevelDistOutside(s, sharpEdges(s), reach)
        case .bevelInside: return bevelDistInside(s, sharpEdges(s), reach)
        case .strokeOutside: return distOutside(s, .chamfer)
        case .chokeInside: return distOutside(s.map { 1 - $0 }, .chamfer)
        case .strokeInside: return distInside(s, .chamfer)
        case .strokeOutsideVector: return distOutside(localCoverage(s), .chamfer)
        }
    }

    enum Metric { case euclidean, chamfer }

    // MARK: Euclidean distance transform

    /// 1D squared distance transform with the nearest seed index.
    static func dt1(_ f: UnsafeMutableBufferPointer<Float>, _ n: Int, _ out: UnsafeMutableBufferPointer<Float>,
                    _ v: UnsafeMutableBufferPointer<Int>, _ z: UnsafeMutableBufferPointer<Float>, _ near: UnsafeMutableBufferPointer<Int>) {
        var k = 0
        v[0] = 0
        z[0] = -.infinity
        z[1] = .infinity
        if n > 1 {
            for q in 1..<n {
                while true {
                    let p = v[k]
                    let s = ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / (2 * Float(q) - 2 * Float(p))
                    if s <= z[k] && k > 0 { k -= 1; continue }
                    if s <= z[k] {
                        v[0] = q; z[0] = -.infinity; z[1] = .infinity
                        break
                    }
                    k += 1; v[k] = q; z[k] = s; z[k + 1] = .infinity
                    break
                }
            }
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let p = v[k]
            let d = Float(q) - Float(p)
            out[q] = d * d + f[p]
            near[q] = p
        }
    }

    /// Exact Euclidean distance to the nearest `inside` pixel plus that pixel's index.
    static func edtNearest(_ inside: [Bool], _ w: Int, _ h: Int) -> ([Float], [Int]) {
        let inf: Float = 1e20
        let total = w * h
        if total != inside.count || total == 0 { return ([Float](repeating: inf, count: inside.count), [Int](repeating: 0, count: inside.count)) }
        let n = max(w, h)
        var gc = [Float](repeating: 0, count: total)   // column-major: gc[x * h + y]
        var nc = [Int](repeating: 0, count: total)
        inside.withUnsafeBufferPointer { ins in
            gc.withUnsafeMutableBufferPointer { gcp in
                nc.withUnsafeMutableBufferPointer { ncp in
                    let (I, G, N) = (UnsafeSendable(ins), UnsafeSendable(gcp), UnsafeSendable(ncp))
                    parallelChunks(w, work: total) { cols in
                        let scratch = Dt1Scratch(n)
                        for x in cols {
                            for y in 0..<h { scratch.f[y] = I.value[y * w + x] ? 0 : inf }
                            dt1(scratch.f, h, scratch.o, scratch.v, scratch.z, scratch.near)
                            for y in 0..<h { G.value[x * h + y] = scratch.o[y]; N.value[x * h + y] = scratch.near[y] }
                        }
                        scratch.free()
                    }
                }
            }
        }
        var g = [Float](repeating: 0, count: total)
        var nearest = [Int](repeating: 0, count: total)
        gc.withUnsafeBufferPointer { gcp in
            nc.withUnsafeBufferPointer { ncp in
                g.withUnsafeMutableBufferPointer { gp in
                    nearest.withUnsafeMutableBufferPointer { np in
                        let (GC, NC, GO, NO) = (UnsafeSendable(gcp), UnsafeSendable(ncp), UnsafeSendable(gp), UnsafeSendable(np))
                        parallelChunks(h, work: total) { rows in
                            let scratch = Dt1Scratch(n)
                            for y in rows {
                                for x in 0..<w { scratch.f[x] = GC.value[x * h + y] }
                                dt1(scratch.f, w, scratch.o, scratch.v, scratch.z, scratch.near)
                                for x in 0..<w {
                                    GO.value[y * w + x] = scratch.o[x].squareRoot()
                                    let px = scratch.near[x]
                                    NO.value[y * w + x] = NC.value[px * h + y] * w + px
                                }
                            }
                            scratch.free()
                        }
                    }
                }
            }
        }
        return (g, nearest)
    }

    final class Dt1Scratch {
        let f, o, z: UnsafeMutableBufferPointer<Float>
        let v, near: UnsafeMutableBufferPointer<Int>
        init(_ n: Int) {
            f = .allocate(capacity: n); o = .allocate(capacity: n); z = .allocate(capacity: n + 1)
            v = .allocate(capacity: n); near = .allocate(capacity: n)
        }
        func free() { f.deallocate(); o.deallocate(); z.deallocate(); v.deallocate(); near.deallocate() }
    }

    // MARK: Chamfer

    /// 5 × 5 chamfer distance from per-pixel start values (`chamferInf` = not a seed).
    static func chamferFrom(_ start: [Float], _ w: Int, _ h: Int) -> [Float] {
        let s2: Float = 1.41421356237309504880168872420969808
        let s5: Float = 2.236_068
        let fwd: [(Int, Int, Float)] = [(-1, 0, 1), (-1, -1, s2), (0, -1, 1), (1, -1, s2), (-1, -2, s5), (1, -2, s5), (-2, -1, s5), (2, -1, s5)]
        var d = start
        d.withUnsafeMutableBufferPointer { dp in
            @inline(__always) func relax(_ x: Int, _ y: Int, _ sign: Int) {
                let i = y * w + x
                var best = dp[i]
                for (ox, oy, wt) in fwd {
                    let nx = x + ox * sign, ny = y + oy * sign
                    if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                    let c = dp[ny * w + nx] + wt
                    if c < best { best = c }
                }
                dp[i] = best
            }
            for y in 0..<h { for x in 0..<w { relax(x, y, 1) } }
            for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) { relax(x, y, -1) } }
        }
        return d
    }

    /// Which pixels of `s` satisfy `test`.
    static func covered(_ s: FxMap, _ test: (Float) -> Bool) -> [Bool] {
        s.v.map(test)
    }

    /// Alpha relative to the 3×3 neighbourhood maximum.
    public static func localCoverage(_ s: FxMap) -> FxMap {
        var out = s
        let (w, h) = (s.w, s.h)
        s.v.withUnsafeBufferPointer { src in
            out.v.withUnsafeMutableBufferPointer { dst in
                let (S, D) = (UnsafeSendable(src), UnsafeSendable(dst))
                parallelRows(h, width: w) { y in
                    for x in 0..<w {
                        let a = S.value[y * w + x]
                        if a <= insideEps { continue }
                        var mx = a
                        for dy in -1...1 {
                            for dx in -1...1 {
                                let (nx, ny) = (x + dx, y + dy)
                                let v: Float = (nx < 0 || ny < 0 || nx >= w || ny >= h) ? 0 : S.value[ny * w + nx]
                                mx = max(mx, v)
                            }
                        }
                        D.value[y * w + x] = min(a / mx, 1)
                    }
                }
            }
        }
        return out
    }

    /// Distance from each pixel centre outside the shape to its edge (≤ 0 inside).
    static func distOutside(_ s: FxMap, _ m: Metric) -> [Float] {
        if m == .chamfer {
            let start = s.v.map { $0 > insideEps ? 1 - min($0, 1) : chamferInf }
            let d = chamferFrom(start, s.w, s.h)
            return zip(d, s.v).map { $1 > insideEps ? -0.5 : $0 - 0.5 }
        }
        let inside = covered(s) { $0 > insideEps }
        let (d, near) = edtNearest(inside, s.w, s.h)
        return (0..<s.v.count).map { i in inside[i] ? -0.5 : d[i] - 0.5 + (1 - min(s.v[near[i]], 1)) }
    }

    /// Distance from each pixel centre inside the shape to its edge (≤ 0 outside).
    static func distInside(_ s: FxMap, _ m: Metric) -> [Float] {
        if m == .chamfer {
            let cov = localCoverage(s)
            let start = (0..<s.v.count).map { i -> Float in
                let a = s.v[i], c = cov.v[i]
                if a <= insideEps { return 0 }
                return c < 1 - insideEps ? c : chamferInf
            }
            let d = chamferFrom(start, s.w, s.h)
            return zip(d, s.v).map { $1 <= insideEps ? -0.5 : $0 - 0.5 }
        }
        let outside = covered(s) { $0 <= insideEps }
        let (d, _) = edtNearest(outside, s.w, s.h)
        return (0..<s.v.count).map { outside[$0] ? -0.5 : d[$0] - 0.5 }
    }

    // MARK: Sharp edges (chiselled bevels)

    /// Signed distance from the centre of a pixel of coverage `a` to the straight edge crossing it.
    static func edgeOffset(_ n: SIMD2<Float>, _ a: Float) -> Float {
        if !a.isFinite { return 0 }
        let u = max(abs(n.x), abs(n.y)), v = min(abs(n.x), abs(n.y))
        let (c0, inside) = a > 0.5 ? (1 - a, true) : (a, false)
        let c = min(max(c0, 0), 0.5)
        let corner = u > 0 ? v / (2 * u) : 0
        let r = c >= corner ? (0.5 - c) * u : 0.5 * (u + v) - (2 * u * v * c).squareRoot()
        return inside ? r : -r
    }

    struct SharpEdge {
        var offset: Float
        var normal: SIMD2<Float>

        static let reach: Float = 0.75

        func distance(_ dx: Float, _ dy: Float, inside: Bool) -> Float? {
            let (nx, ny) = (normal.x, normal.y)
            if nx == 0 && ny == 0 { return nil }
            let signed = offset + dx * nx + dy * ny
            let across = inside ? signed : -signed
            let along = abs(dx * -ny + dy * nx)
            return across > 0 ? hypotf(across, max(along - SharpEdge.reach, 0)) : nil
        }
    }

    struct EdgePixel {
        var at: Int
        var cov: Float
        var edge: SharpEdge
    }

    struct SharpEdges {
        var w: Int, h: Int
        var slot: [UInt32]
        var pixels: [EdgePixel]

        static func empty(_ w: Int, _ h: Int) -> SharpEdges { SharpEdges(w: w, h: h, slot: [], pixels: []) }

        func get(_ i: Int) -> SharpEdge? {
            guard i < slot.count else { return nil }
            let k = Int(slot[i])
            return k == 0 ? nil : pixels[k - 1].edge
        }

        func at(_ x: Int, _ y: Int) -> SharpEdge? { (x < 0 || y < 0 || x >= w || y >= h) ? nil : get(y * w + x) }
        func has(_ x: Int, _ y: Int) -> Bool { at(x, y) != nil }
        var isEmpty: Bool { pixels.isEmpty }
    }

    static func sharpEdges(_ s: FxMap) -> SharpEdges {
        let (w, h) = (s.w, s.h)
        if w == 0 || h == 0 || s.v.count != w * h { return .empty(w, h) }
        func get(_ x: Int, _ y: Int) -> Float { s.get(x, y) }
        func covAt(_ x: Int, _ y: Int) -> Float {
            let a = s.v[y * w + x]
            if a <= insideEps { return a }
            var mx = a
            for dy in -1...1 { for dx in -1...1 { mx = max(mx, get(x + dx, y + dy)) } }
            return min(a / mx, 1)
        }
        func covClamped(_ x: Int, _ y: Int) -> Float { covAt(min(max(x, 0), w - 1), min(max(y, 0), h - 1)) }
        func solid(_ x: Int, _ y: Int) -> Bool {
            if x < 0 || y < 0 || x >= w || y >= h { return true }
            let a = s.v[y * w + x]
            return a.isNaN || a > insideEps
        }
        var rows = [[EdgePixel]](repeating: [], count: h)
        rows.withUnsafeMutableBufferPointer { rp in
            let R = UnsafeSendable(rp)
            parallelRows(h, width: w) { y in
                var row: [EdgePixel] = []
                for x in 0..<w {
                    if !solid(x, y) { continue }
                    var allSolid = true
                    for dy in -1...1 { for dx in -1...1 where !solid(x + dx, y + dy) { allSolid = false } }
                    if allSolid { continue }
                    let i = y * w + x
                    let c = covAt(x, y)
                    if s.v[i] <= insideEps || c >= 1 - insideEps { continue }
                    var empty = false, full = false
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let (nx, ny) = (x + dx, y + dy)
                            if (dx == 0 && dy == 0) || nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                            if get(nx, ny) <= insideEps { empty = true }
                            if covAt(nx, ny) >= 1 - insideEps { full = true }
                        }
                    }
                    if !(empty && full) { continue }
                    let gx = (covClamped(x + 1, y - 1) + 2 * covClamped(x + 1, y) + covClamped(x + 1, y + 1))
                        - (covClamped(x - 1, y - 1) + 2 * covClamped(x - 1, y) + covClamped(x - 1, y + 1))
                    let gy = (covClamped(x - 1, y + 1) + 2 * covClamped(x, y + 1) + covClamped(x + 1, y + 1))
                        - (covClamped(x - 1, y - 1) + 2 * covClamped(x, y - 1) + covClamped(x + 1, y - 1))
                    let len = hypotf(gx, gy)
                    let normal: SIMD2<Float>, n: SIMD2<Float>
                    if len.isFinite && len > 1e-6 { normal = SIMD2(gx / len, gy / len); n = normal } else { normal = .zero; n = SIMD2(1, 0) }
                    row.append(EdgePixel(at: i, cov: c, edge: SharpEdge(offset: edgeOffset(n, c), normal: normal)))
                }
                R.value[y] = row
            }
        }
        var pixels: [EdgePixel] = []
        for r in rows { pixels.append(contentsOf: r) }
        var slot = [UInt32](repeating: 0, count: w * h)
        for (k, p) in pixels.enumerated() { slot[p.at] = UInt32(k + 1) }
        refineEdgeNormals(&pixels, slot, w, h)
        return SharpEdges(w: w, h: h, slot: slot, pixels: pixels)
    }

    static let normalRadius = 3
    static let edgeLineMinSpread: Float = 0.7
    static let edgeLineMaxOff: Float = 0.1

    static func refineEdgeNormals(_ pixels: inout [EdgePixel], _ slot: [UInt32], _ w: Int, _ h: Int) {
        let points: [SIMD2<Float>] = pixels.map { p in
            SIMD2(Float(p.at % w) - p.edge.offset * p.edge.normal.x, Float(p.at / w) - p.edge.offset * p.edge.normal.y)
        }
        let before = pixels.map(\.edge)
        let r = normalRadius
        pixels.withUnsafeMutableBufferPointer { pp in
            let P = UnsafeSendable(pp)
            parallelChunks(pp.count, work: pp.count * 32) { range in
                var near: [SIMD2<Float>] = []
                for k in range {
                    let e = before[k]
                    let at = P.value[k].at
                    let (x, y) = (at % w, at / w)
                    var n: Float = 0
                    var sum = SIMD2<Float>.zero
                    near.removeAll(keepingCapacity: true)
                    for dy in -r...r {
                        for dx in -r...r {
                            let (nx, ny) = (x + dx, y + dy)
                            if dx * dx + dy * dy > r * r || nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                            let s = Int(slot[ny * w + nx])
                            if s == 0 { continue }
                            let j = s - 1
                            let o = before[j], p = points[j]
                            if o.normal.x * e.normal.x + o.normal.y * e.normal.y > 0.9 {
                                near.append(p); sum += p; n += 1
                            }
                        }
                    }
                    if near.count < 3 { continue }
                    let mean = sum / n
                    var (sxx, sxy, syy): (Float, Float, Float) = (0, 0, 0)
                    for p in near {
                        let (dx, dy) = (p.x - mean.x, p.y - mean.y)
                        sxx += dx * dx; sxy += dx * dy; syy += dy * dy
                    }
                    let half = 0.5 * (sxx + syy)
                    let root = (0.25 * (sxx - syy) * (sxx - syy) + sxy * sxy).squareRoot()
                    let along = max((half + root) / n, 0).squareRoot(), across = max((half - root) / n, 0).squareRoot()
                    if !(along > edgeLineMinSpread && across < edgeLineMaxOff) { continue }
                    let angle = 0.5 * atan2f(2 * sxy, sxx - syy)
                    var normal = SIMD2<Float>(-sinf(angle), cosf(angle))
                    if normal.x * e.normal.x + normal.y * e.normal.y < 0 { normal = -normal }
                    P.value[k].edge.normal = normal
                    P.value[k].edge.offset = edgeOffset(normal, P.value[k].cov)
                }
            }
        }
    }

    static let footRadius = 2
    static let edgeMargin: Float = 2

    static func edgeDistance(_ sharp: SharpEdges, _ p: (Int, Int), _ q: (Int, Int), inside: Bool) -> Float? {
        let (px, py) = (Float(p.0), Float(p.1))
        guard let e = sharp.at(q.0, q.1), var best = e.distance(px - Float(q.0), py - Float(q.1), inside: inside) else { return nil }
        let signed = e.offset + (px - Float(q.0)) * e.normal.x + (py - Float(q.1)) * e.normal.y
        let fx = Int((px - signed * e.normal.x).rounded()), fy = Int((py - signed * e.normal.y).rounded())
        let ylo = max(fy - footRadius, 0), yhi = min(fy + footRadius, sharp.h - 1)
        let xlo = max(fx - footRadius, 0), xhi = min(fx + footRadius, sharp.w - 1)
        if ylo <= yhi && xlo <= xhi {
            for sy in ylo...yhi {
                for sx in xlo...xhi {
                    if let near = sharp.at(sx, sy), let d = near.distance(px - Float(sx), py - Float(sy), inside: inside) { best = min(best, d) }
                }
            }
        }
        return best
    }

    static func bevelDistInside(_ s: FxMap, _ sharp: SharpEdges, _ reach: Float) -> [Float] {
        let empty = covered(s) { $0 <= insideEps }
        let (d, near) = edtNearest(empty, s.w, s.h)
        let w = s.w
        var out = [Float](repeating: 0, count: s.v.count)
        out.withUnsafeMutableBufferPointer { op in
            let O = UnsafeSendable(op)
            parallelRows(s.h, width: w) { y in
                for x in 0..<w {
                    let i = y * w + x
                    if empty[i] { O.value[i] = -0.5; continue }
                    if let e = sharp.get(i) { O.value[i] = e.offset; continue }
                    let plain = d[i] - 0.5
                    if d[i] > reach + edgeMargin || sharp.isEmpty { O.value[i] = plain; continue }
                    let (ox, oy) = (near[i] % w, near[i] / w)
                    var q: (Int, Int)?
                    var bestD = Int.max
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let (cx, cy) = (ox + dx, oy + dy)
                            guard cx >= 0, cy >= 0, sharp.has(cx, cy) else { continue }
                            let dd = (cx - x) * (cx - x) + (cy - y) * (cy - y)
                            if dd < bestD { bestD = dd; q = (cx, cy) }
                        }
                    }
                    if let q, let refined = edgeDistance(sharp, (x, y), q, inside: true) {
                        O.value[i] = min(refined, plain)
                    } else {
                        O.value[i] = plain
                    }
                }
            }
        }
        return out
    }

    static func bevelDistOutside(_ s: FxMap, _ sharp: SharpEdges, _ reach: Float) -> [Float] {
        let inside = covered(s) { $0 > insideEps }
        let (d, near) = edtNearest(inside, s.w, s.h)
        let w = s.w
        var out = [Float](repeating: 0, count: s.v.count)
        out.withUnsafeMutableBufferPointer { op in
            let O = UnsafeSendable(op)
            parallelRows(s.h, width: w) { y in
                for x in 0..<w {
                    let i = y * w + x
                    if let e = sharp.get(i) { O.value[i] = -e.offset; continue }
                    if inside[i] { O.value[i] = -0.5; continue }
                    let q = near[i]
                    guard let e = sharp.get(q) else { O.value[i] = d[i] - (min(s.v[q], 1) - 0.5); continue }
                    let qp = (q % w, q / w)
                    let measured: Float?
                    if d[i] <= reach + edgeMargin {
                        measured = edgeDistance(sharp, (x, y), qp, inside: false)
                    } else {
                        measured = e.distance(Float(x - qp.0), Float(y - qp.1), inside: false)
                    }
                    O.value[i] = measured ?? (d[i] - e.offset)
                }
            }
        }
        return out
    }
}
