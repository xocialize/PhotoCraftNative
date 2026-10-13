// Port of photocraft-algo (crates/algo/src/puppet.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edit › Puppet Warp: pins on a triangle mesh over the layer's opaque region, deformed
// as-rigidly-as-possible.
//
// * Mesh: the coverage (alpha above 0.05) becomes a signed distance field over a block grid
//   (Felzenszwalb & Huttenlocher's separable EDT), offset by the expansion; its zero crossing is
//   traced by marching squares, simplified (Douglas–Peucker) and split into sides of the
//   density's spacing; a triangular lattice fills the inside; the Delaunay triangulation
//   (Bowyer–Watson) of those points with the outline's sides recovered, minus the triangles
//   outside, is the mesh, numbered in reverse Cuthill–McKee order.
// * Deformation: the per-triangle ARAP energy of Liu et al. 2008 (the triangle form of Sorkine &
//   Alexa 2007) with cotangent weights, alternating a local step (best rotation per triangle;
//   Distort fits similarities, Normal rotation × √scale) and a global step (banded Cholesky, or
//   Jacobi-preconditioned CG when the band is too wide). Pins are stiff soft constraints on the
//   barycentric point under them; a pin's rotation fixes R on the triangles around it; mesh
//   components without a pin stay where they are.
// * Rendering: the deformed triangles are rasterised back to front by the depth of their nearest
//   pin through `MeshWarp.warpTriangles` (sampled on the GPU).

import Foundation
import PCFoundation

public enum PuppetMode: String, Codable, Sendable, Hashable, CaseIterable {
    case rigid
    case normal
    case distort

    public static let `default` = PuppetMode.normal

    public init?(parsing s: String) {
        switch s.lowercased() {
        case "rigid": self = .rigid
        case "normal": self = .normal
        case "distort": self = .distort
        default: return nil
        }
    }
}

public enum PuppetDensity: String, Codable, Sendable, Hashable, CaseIterable {
    case fewer
    case normal
    case more

    public static let `default` = PuppetDensity.normal

    public init?(parsing s: String) {
        switch s.lowercased() {
        case "fewer", "fewerpoints": self = .fewer
        case "normal": self = .normal
        case "more", "morepoints": self = .more
        default: return nil
        }
    }

    var cells: Double {
        switch self { case .fewer: 12; case .normal: 20; case .more: 32 }
    }
}

/// A pin: where it was placed (`src`) and where it is now (`dst`), document pixels (photocraft
/// `PuppetPin`).
public struct PuppetPin: Hashable, Sendable, Codable {
    public var src: SIMD2<Double>
    public var dst: SIMD2<Double>
    /// Fixed rotation of the mesh around the pin (degrees); nil = automatic.
    public var rotate: Double?
    /// Pin depth: where the mesh overlaps itself, triangles nearest a higher pin draw on top.
    public var depth: Int32

    public init(src: SIMD2<Double>, dst: SIMD2<Double>, rotate: Double? = nil, depth: Int32 = 0) {
        self.src = src; self.dst = dst; self.rotate = rotate; self.depth = depth
    }

    enum CodingKeys: String, CodingKey { case src, dst, rotate, depth }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        src = try c.decode(SIMD2<Double>.self, forKey: .src)
        dst = try c.decode(SIMD2<Double>.self, forKey: .dst)
        rotate = try c.decodeIfPresent(Double.self, forKey: .rotate)
        depth = try c.decodeIfPresent(Int32.self, forKey: .depth) ?? 0
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(src, forKey: .src)
        try c.encode(dst, forKey: .dst)
        try c.encodeIfPresent(rotate, forKey: .rotate)
        if depth != 0 { try c.encode(depth, forKey: .depth) }
    }
}

/// A complete puppet warp: the command's params and a smart filter's stored data (photocraft
/// `PuppetWarp`).
public struct PuppetWarp: Hashable, Sendable, Codable {
    public var pins: [PuppetPin]
    public var mode: PuppetMode
    public var density: PuppetDensity
    /// Grows (or with a negative value shrinks) the mesh beyond the opaque region, px.
    public var expansion: Double

    public init(pins: [PuppetPin] = [], mode: PuppetMode = .normal, density: PuppetDensity = .normal, expansion: Double = 2) {
        self.pins = pins; self.mode = mode; self.density = density; self.expansion = expansion
    }

    enum CodingKeys: String, CodingKey { case pins, mode, density, expansion }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pins = try c.decodeIfPresent([PuppetPin].self, forKey: .pins) ?? []
        mode = try c.decodeIfPresent(PuppetMode.self, forKey: .mode) ?? .normal
        density = try c.decodeIfPresent(PuppetDensity.self, forKey: .density) ?? .normal
        expansion = try c.decodeIfPresent(Double.self, forKey: .expansion) ?? 2
    }

    public var isIdentity: Bool {
        pins.allSatisfy { p in p.src == p.dst && (p.rotate.map { PuppetKit.remEuclid($0, 360) == 0 } ?? true) }
    }
}

/// A triangle mesh in document pixels (photocraft `PuppetMesh`).
public struct PuppetMesh: Hashable, Sendable {
    public var verts: [SIMD2<Double>]
    public var tris: [SIMD3<Int32>]
    /// Grid spacing (px).
    public var spacing: Double
    public init(verts: [SIMD2<Double>] = [], tris: [SIMD3<Int32>] = [], spacing: Double = 0) { self.verts = verts; self.tris = tris; self.spacing = spacing }
}

/// Puppet Warp functions (photocraft `puppet.rs`).
public enum Puppet {
    /// Number of local/global rounds the command uses.
    public static let iterations = 40
    /// The largest area (px) a result may span: 2³⁰ (photocraft #1019).
    public static let maxWarpPixels = Double(1 << 30)

    /// Builds the mesh over the covered part of `src` inside `bounds` (photocraft `build_mesh`).
    public static func buildMesh(_ src: Surface, bounds: PixelRect, density: PuppetDensity, expansion: Double) -> PuppetMesh {
        PuppetKit.buildMesh(PuppetKit.Coverage(src), bounds, density, expansion)
    }

    /// `buildMesh` over a dense image (alpha from `context`, 0 outside the image).
    public static func buildMesh(_ img: FloatImage, bounds: PixelRect, density: PuppetDensity, expansion: Double, context: FilterContext? = nil) -> PuppetMesh {
        let ctx = context ?? FilterContext.inferred(channels: img.channels, bounds: img.rect)
        return PuppetKit.buildMesh(PuppetKit.Coverage(img, alpha: ctx.alpha), bounds, density, expansion)
    }

    /// The deformed mesh of a puppet warp: (solver, deformed vertices, draw order) — photocraft
    /// `deform`.
    public static func deform(_ mesh: PuppetMesh, _ w: PuppetWarp, iterations: Int = Puppet.iterations) -> (PuppetSolver, [SIMD2<Double>], [Int]) {
        let pinSrc = w.pins.map(\.src)
        let solver = PuppetSolver(mesh: mesh, pinSrc: pinSrc, fixedRotation: w.pins.map { $0.rotate != nil })
        let (v, _) = solver.solve(pinDst: w.pins.map(\.dst), rotations: w.pins.map(\.rotate), mode: w.mode, iterations: iterations, initial: nil)
        let order = solver.drawOrder(depths: w.pins.map(\.depth), pinSrc: pinSrc)
        return (solver, v, order)
    }

    /// The triangles (in draw order) and textured vertices that render a deformation.
    static func renderMesh(_ mesh: PuppetMesh, _ deformed: [SIMD2<Double>], _ order: [Int]) -> ([MeshWarp.Vertex], [SIMD3<Int32>]) {
        let verts = zip(deformed, mesh.verts).map { MeshWarp.Vertex(dst: $0, src: $1) }
        return (verts, order.map { mesh.tris[$0] })
    }

    /// Rasterises the mesh deformation of `src` (inside `bounds`): the deformed triangles only, so
    /// pixels outside the mesh are dropped (photocraft `render`).
    public static func render(_ src: Surface, bounds: PixelRect, mesh: PuppetMesh, deformed: [SIMD2<Double>], order: [Int], interp: Interp = .bicubic,
                              on backend: Backend = .auto) -> Surface {
        let (verts, tris) = renderMesh(mesh, deformed, order)
        return MeshWarp.warpTriangles(src, srcRect: bounds, verts: verts, tris: tris, interp: interp, on: backend)
    }

    /// Applies a puppet warp to `src` (content inside `bounds`); nil when the deformed mesh would
    /// span more than `maxWarpPixels` (photocraft `puppet_warp`).
    public static func warp(_ src: Surface, bounds: PixelRect, _ w: PuppetWarp, interp: Interp = .bicubic, on backend: Backend = .auto) -> Surface? {
        let mesh = buildMesh(src, bounds: bounds, density: w.density, expansion: w.expansion)
        let (solver, v, order) = deform(mesh, w)
        // No triangles (an expansion that shrinks every pixel away): nothing to warp.
        if solver.mesh.tris.isEmpty { return src }
        if !PuppetKit.withinLimit(v) { return nil }
        return render(src, bounds: bounds, mesh: solver.mesh, deformed: v, order: order, interp: interp, on: backend)
    }

    /// `warp` on a dense image (0 outside it): the result covers the deformed mesh's bounds (alpha
    /// appended when `context` has none), or the image itself when the mesh is empty.
    public static func warp(_ img: FloatImage, bounds: PixelRect? = nil, _ w: PuppetWarp, interp: Interp = .bicubic, context: FilterContext? = nil,
                            on backend: Backend = .auto) throws -> FloatImage? {
        let b = bounds ?? img.rect
        let mesh = buildMesh(img, bounds: b, density: w.density, expansion: w.expansion, context: context)
        let (solver, v, order) = deform(mesh, w)
        if solver.mesh.tris.isEmpty { return img }
        if !PuppetKit.withinLimit(v) { return nil }
        let (verts, tris) = renderMesh(solver.mesh, v, order)
        return try MeshWarp.warpTriangles(img, srcRect: b, verts: verts, tris: tris, interp: interp, context: context, on: backend)
    }
}

enum PuppetKit {
    /// Coverage threshold: alpha above this counts as part of the puppet.
    static let alphaMin: Float = 0.05
    /// The outline field's longest side, in blocks.
    static let fieldBlocks = 1024.0
    /// Most outline points the mesh takes; a busier outline is simplified more coarsely.
    static let maxOutlinePoints = 20_000
    static let none = Int.max

    static func remEuclid(_ a: Double, _ b: Double) -> Double {
        let r = fmod(a, b)
        return r < 0 ? r + abs(b) : r
    }

    @inline(__always) static func dist2(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    static func withinLimit(_ v: [SIMD2<Double>]) -> Bool {
        var (x0, y0, x1, y1) = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        for p in v { x0 = fmin(x0, p.x); y0 = fmin(y0, p.y); x1 = fmax(x1, p.x); y1 = fmax(y1, p.y) }
        let area = (x1 - x0 + 1) * (y1 - y0 + 1)
        return !(area.isNaN || area > Puppet.maxWarpPixels)
    }

    /// Where the alpha comes from: a surface (sparse) or a dense image.
    struct Coverage {
        let alpha: Bool
        /// Alpha values over a rectangle, nil when nothing is stored there.
        let read: (PixelRect) -> [Float]?

        init(_ s: Surface) {
            alpha = s.format.alpha
            let n = s.channels
            read = { r in
                if r.isEmpty || !r.tiles.contains(where: { s.tile($0) != nil }) { return nil }
                let px = s.readRegion(r)
                return (0..<r.area).map { px[$0 * n + n - 1] }
            }
        }

        init(_ img: FloatImage, alpha: Bool) {
            self.alpha = alpha
            let n = img.channels
            read = { r in
                if r.intersect(img.rect).isEmpty { return nil }
                let px = img.crop(r).data
                return (0..<r.area).map { px[$0 * n + n - 1] }
            }
        }
    }

    /// The puppet's region as a signed distance field over a block grid: negative inside the
    /// opaque area grown (or shrunk) by the expansion, positive outside, px.
    struct Field {
        var x0: Double
        var y0: Double
        /// Block size (px).
        var g: Double
        var bw: Int
        var bh: Int
        var sd: [Float]
        var expansion: Double

        init(_ cov: Coverage, _ bounds: PixelRect, _ expansion: Double) {
            let long = Double(max(bounds.width, bounds.height))
            let grow = fmax(expansion, 0).rounded(.up)
            let g = Int32(fmax(((long + 2 * grow + 8) / fieldBlocks).rounded(.up), 1))
            let area = bounds.outset(by: Int32(grow) + 2 * g)
            let bw = Int(max((Int32(area.width) + g - 1) / g, 1)), bh = Int(max((Int32(area.height) + g - 1) / g, 1))
            var mask = [Bool](repeating: false, count: bw * bh)
            func block(_ bx: Int, _ by: Int) -> PixelRect {
                let x = area.x0 + Int32(bx) * g, y = area.y0 + Int32(by) * g
                return PixelRect(x0: x, y0: y, x1: x + g, y1: y + g)
            }
            if !cov.alpha {
                for i in mask.indices { mask[i] = !block(i % bw, i / bw).intersect(bounds).isEmpty }
            } else {
                mask.withUnsafeMutableBufferPointer { mb in
                    let m = UnsafeSendable(mb)
                    parallelFor(bh) { by in
                        let r = PixelRect(x0: area.x0, y0: area.y0 + Int32(by) * g, x1: area.x0 + Int32(bw) * g, y1: area.y0 + (Int32(by) + 1) * g).intersect(bounds)
                        if r.isEmpty { return }
                        guard let row = cov.read(r) else { return }
                        let rw = r.width
                        for (i, a) in row.enumerated() where a > alphaMin {
                            let x = r.x0 + Int32(i % rw)
                            let bx = Int((x - area.x0) / g)
                            if bx < bw { m.value[by * bw + bx] = true }
                        }
                    }
                }
            }
            let outside = PuppetKit.edt(mask, true, bw, bh)
            let inside = PuppetKit.edt(mask, false, bw, bh)
            let gf = Double(g)
            sd = (0..<(bw * bh)).map { i in mask[i] ? Float(-(inside[i].squareRoot() - 0.5) * gf) : Float((outside[i].squareRoot() - 0.5) * gf) }
            x0 = Double(area.x0); y0 = Double(area.y0); self.g = gf; self.bw = bw; self.bh = bh; self.expansion = expansion
        }

        /// The field at a block centre (exact).
        @inline(__always)
        func at(_ bx: Int, _ by: Int) -> Double {
            let i = by * bw + bx
            return i < sd.count ? Double(sd[i]) - expansion : Double.greatestFiniteMagnitude
        }

        /// The field at `p` (bilinear between block centres, clamped to the grid).
        func value(_ p: SIMD2<Double>) -> Double {
            let fx = GeometryKit.clampR((p.x - x0) / g - 0.5, 0, Double(bw - 1))
            let fy = GeometryKit.clampR((p.y - y0) / g - 0.5, 0, Double(bh - 1))
            let ix = Int(fx.rounded(.down)), iy = Int(fy.rounded(.down))
            let ix1 = min(ix + 1, bw - 1), iy1 = min(iy + 1, bh - 1)
            let tx = fx - Double(ix), ty = fy - Double(iy)
            let top = at(ix, iy) * (1 - tx) + at(ix1, iy) * tx
            let bottom = at(ix, iy1) * (1 - tx) + at(ix1, iy1) * tx
            return top * (1 - ty) + bottom * ty
        }

        /// The outline as closed loops, traced by marching squares over the block centres.
        func outline() -> [[SIMD2<Double>]] {
            if bw < 2 || bh < 2 { return [] }
            func inside(_ x: Int, _ y: Int) -> Bool { at(x, y) < 0 }
            // A crossing is named by its block edge: 2·block for the edge to the right neighbour,
            // 2·block + 1 for the edge to the one below.
            func id(_ x: Int, _ y: Int, _ down: Bool) -> Int { 2 * (y * bw + x) + (down ? 1 : 0) }
            func point(_ id: Int) -> SIMD2<Double> {
                let b = id / 2
                let x = b % bw, y = b / bw
                let (x2, y2) = id % 2 == 0 ? (x + 1, y) : (x, y + 1)
                let fa = at(x, y), fb = at(x2, y2)
                let t = abs(fa - fb) > 1e-12 ? GeometryKit.clampR(fa / (fa - fb), 0, 1) : 0.5
                let dx = Double(x2 - x), dy = Double(y2 - y)
                return SIMD2(x0 + (Double(x) + 0.5 + dx * t) * g, y0 + (Double(y) + 0.5 + dy * t) * g)
            }
            var links: [Int: (Int, Int)] = [:]
            func link(_ a: Int, _ b: Int) {
                for (p, q) in [(a, b), (b, a)] {
                    var e = links[p] ?? (none, none)
                    if e.0 == none { e.0 = q } else { e.1 = q }
                    links[p] = e
                }
            }
            for y in 0..<(bh - 1) {
                for x in 0..<(bw - 1) {
                    let c = [inside(x, y), inside(x + 1, y), inside(x + 1, y + 1), inside(x, y + 1)]
                    if c.allSatisfy({ $0 == c[0] }) { continue }
                    // Top, right, bottom, left.
                    let edges = [id(x, y, false), id(x + 1, y, true), id(x, y + 1, false), id(x, y, true)]
                    let cross = [c[0] != c[1], c[1] != c[2], c[3] != c[2], c[0] != c[3]]
                    let ks = (0..<4).filter { cross[$0] }
                    if ks.count == 2 {
                        link(edges[ks[0]], edges[ks[1]])
                    } else if ks.count == 4 {
                        // A saddle: the centre decides which diagonal pair is joined.
                        let centre = at(x, y) + at(x + 1, y) + at(x + 1, y + 1) + at(x, y + 1) < 0
                        if c[0] == centre {
                            link(edges[0], edges[1])
                            link(edges[2], edges[3])
                        } else {
                            link(edges[3], edges[0])
                            link(edges[1], edges[2])
                        }
                    }
                }
            }
            let keys = links.keys.sorted()
            var seen = Set<Int>()
            seen.reserveCapacity(keys.count)
            var loops: [[SIMD2<Double>]] = []
            for start in keys where !seen.contains(start) {
                var lp: [SIMD2<Double>] = []
                var prev = none, cur = start
                while true {
                    seen.insert(cur)
                    lp.append(point(cur))
                    guard let (a, b) = links[cur] else { break }
                    let next = a != prev ? a : b
                    if next == none || seen.contains(next) { break }
                    (prev, cur) = (cur, next)
                }
                if lp.count >= 3 { loops.append(lp) }
            }
            return loops
        }
    }

    /// Squared Euclidean distance (in blocks) from every block to the nearest block whose mask
    /// equals `site` (Felzenszwalb & Huttenlocher); about 1e20 when there is none.
    static func edt(_ mask: [Bool], _ site: Bool, _ w: Int, _ h: Int) -> [Double] {
        let far = 1e20
        var d = mask.map { $0 == site ? 0.0 : far }
        let m = max(w, h)
        var f = [Double](repeating: 0, count: m), out = [Double](repeating: 0, count: m)
        var v = [Int](repeating: 0, count: m), z = [Double](repeating: 0, count: m + 1)
        for x in 0..<w {
            for y in 0..<h { f[y] = d[y * w + x] }
            edt1d(f, h, &out, &v, &z)
            for y in 0..<h { d[y * w + x] = out[y] }
        }
        for y in 0..<h {
            for x in 0..<w { f[x] = d[y * w + x] }
            edt1d(f, w, &out, &v, &z)
            for x in 0..<w { d[y * w + x] = out[x] }
        }
        return d
    }

    /// One-dimensional squared distance transform of the first `n` samples of `f`.
    static func edt1d(_ f: [Double], _ n: Int, _ out: inout [Double], _ v: inout [Int], _ z: inout [Double]) {
        if n == 0 { return }
        var k = 0
        v[0] = 0
        z[0] = -Double.infinity
        z[1] = Double.infinity
        func meet(_ q: Int, _ p: Int) -> Double {
            let qf = Double(q), pf = Double(p)
            return ((f[q] + qf * qf) - (f[p] + pf * pf)) / (2 * (qf - pf))
        }
        if n > 1 {
            for q in 1..<n {
                var s = meet(q, v[k])
                while k > 0 && s <= z[k] {
                    k -= 1
                    s = meet(q, v[k])
                }
                k += 1
                v[k] = q
                z[k] = s
                z[k + 1] = Double.infinity
            }
        }
        k = 0
        for q in 0..<n {
            let qf = Double(q)
            while z[k + 1] < qf { k += 1 }
            let p = v[k]
            let dq = qf - Double(p)
            out[q] = dq * dq + f[p]
        }
    }

    /// Distance from `p` to the segment `a`–`b`.
    static func segDist(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        let t = l2 > 0 ? GeometryKit.clampR(((p.x - a.x) * dx + (p.y - a.y) * dy) / l2, 0, 1) : 0
        return dist2(p, SIMD2(a.x + dx * t, a.y + dy * t)).squareRoot()
    }

    /// Simplifies a closed loop (Douglas–Peucker within `tol` px), keeping its corners.
    static func simplify(_ lp: [SIMD2<Double>], _ tol: Double) -> [SIMD2<Double>] {
        let n = lp.count
        if n < 4 { return lp }
        // Rust's `max_by` keeps the last of equal maxima.
        var far = n / 2, best = -Double.infinity
        for a in 1..<n {
            let d = dist2(lp[0], lp[a])
            if d >= best { best = d; far = a }
        }
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true
        keep[far] = true
        var stack = [(0, far), (far, n)]
        while let (a, b) = stack.popLast() {
            let pa = lp[a], pb = lp[b % n]
            var bd = 0.0, bi = 0
            if a + 1 < b {
                for i in (a + 1)..<b {
                    let d = segDist(lp[i], pa, pb)
                    if d > bd { bd = d; bi = i }
                }
            }
            if bd > tol {
                keep[bi] = true
                stack.append((a, bi))
                stack.append((bi, b))
            }
        }
        let out = (0..<n).filter { keep[$0] }.map { lp[$0] }
        if out.count >= 3 { return out }
        // A speck thinner than the tolerance: keep a few of its points.
        return Swift.stride(from: 0, to: n, by: max(n / 4, 1)).map { lp[$0] }
    }

    /// Splits the sides of a closed loop longer than `step` into equal parts.
    static func densify(_ lp: [SIMD2<Double>], _ step: Double) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        out.reserveCapacity(lp.count)
        for (k, a) in lp.enumerated() {
            let b = lp[(k + 1) % lp.count]
            let parts = Int(GeometryKit.clampR((dist2(a, b).squareRoot() / step).rounded(.up), 1, 1e4))
            for i in 0..<parts { out.append(lerp(a, b, Double(i) / Double(parts))) }
        }
        return out
    }

    @inline(__always) static func lerp(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ t: Double) -> SIMD2<Double> {
        SIMD2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }

    @inline(__always) static func orient(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    /// Positive when `d` lies inside the circumcircle of the positively oriented `a`, `b`, `c`.
    @inline(__always) static func inCircle(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Double {
        let ax = a.x - d.x, ay = a.y - d.y
        let bx = b.x - d.x, by = b.y - d.y
        let cx = c.x - d.x, cy = c.y - d.y
        return (ax * ax + ay * ay) * (bx * cy - cx * by) - (bx * bx + by * by) * (ax * cy - cx * ay) + (cx * cx + cy * cy) * (ax * by - bx * ay)
    }

    /// A triangle of the Delaunay triangulation: vertices (positively oriented) and the neighbour
    /// across the edge opposite each vertex.
    struct DTri {
        var v: (Int, Int, Int)
        var n: (Int, Int, Int)
        var alive: Bool
        @inline(__always) func vert(_ k: Int) -> Int { k == 0 ? v.0 : (k == 1 ? v.1 : v.2) }
        @inline(__always) func nb(_ k: Int) -> Int { k == 0 ? n.0 : (k == 1 ? n.1 : n.2) }
        @inline(__always) mutating func setNb(_ k: Int, _ x: Int) { if k == 0 { n.0 = x } else if k == 1 { n.1 = x } else { n.2 = x } }
    }

    /// Incremental Delaunay triangulation (Bowyer–Watson) from a triangle around the area; vertices
    /// 0..<3 are that triangle's.
    struct Delaunay {
        var pts: [SIMD2<Double>]
        var tris: [DTri]
        var stamp: [UInt32]
        var pass: UInt32 = 0
        var last = 0

        init(_ lo: SIMD2<Double>, _ hi: SIMD2<Double>) {
            let cx = 0.5 * (lo.x + hi.x), cy = 0.5 * (lo.y + hi.y)
            let d = fmax(fmax(hi.x - lo.x, hi.y - lo.y), 1) * 4
            var p = [SIMD2(cx - 2 * d, cy - d), SIMD2(cx + 2 * d, cy - d), SIMD2(cx, cy + 2 * d)]
            if PuppetKit.orient(p[0], p[1], p[2]) < 0 { p.swapAt(1, 2) }
            pts = p
            tris = [DTri(v: (0, 1, 2), n: (none, none, none), alive: true)]
            stamp = [0]
        }

        /// The triangle holding `p`: a visibility walk from the last one made.
        func locate(_ p: SIMD2<Double>) -> Int? {
            var t: Int
            if last < tris.count && tris[last].alive { t = last } else {
                guard let f = tris.firstIndex(where: { $0.alive }) else { return nil }
                t = f
            }
            for _ in 0..<(tris.count + 3) {
                let tri = tris[t]
                var step: Int? = nil
                for k in 0..<3 where PuppetKit.orient(pts[tri.vert((k + 1) % 3)], pts[tri.vert((k + 2) % 3)], p) < 0 { step = k; break }
                guard let k = step else { return t }
                if tri.nb(k) != none { t = tri.nb(k) } else { return nil }
            }
            return tris.firstIndex { tri in tri.alive && (0..<3).allSatisfy { PuppetKit.orient(pts[tri.vert(($0 + 1) % 3)], pts[tri.vert(($0 + 2) % 3)], p) >= 0 } }
        }

        /// Inserts `p`; returns its vertex index (an existing vertex's when `p` coincides with it).
        mutating func insert(_ p: SIMD2<Double>) -> Int? {
            guard let t0 = locate(p) else { return nil }
            for k in 0..<3 {
                let v = tris[t0].vert(k)
                if PuppetKit.dist2(pts[v], p) < 1e-12 { return v }
            }
            pass = pass &+ 1
            let ps = pass
            // The cavity: every triangle whose circumcircle holds `p`, grown from `t0`.
            var bad = [t0]
            stamp[t0] = ps
            var i = 0
            while i < bad.count {
                let t = bad[i]
                i += 1
                for k in 0..<3 {
                    let nb = tris[t].nb(k)
                    if nb == none || stamp[nb] == ps { continue }
                    let tv = tris[nb]
                    if PuppetKit.inCircle(pts[tv.v.0], pts[tv.v.1], pts[tv.v.2], p) > 0 {
                        stamp[nb] = ps
                        bad.append(nb)
                    }
                }
            }
            var rim: [(Int, Int, Int)] = []
            for t in bad {
                let tri = tris[t]
                for k in 0..<3 {
                    let nb = tri.nb(k)
                    if nb == none || stamp[nb] != ps { rim.append((tri.vert((k + 1) % 3), tri.vert((k + 2) % 3), nb)) }
                }
                tris[t].alive = false
            }
            let pi = pts.count
            pts.append(p)
            let base = tris.count
            for (i, (a, b, o)) in rim.enumerated() {
                tris.append(DTri(v: (a, b, pi), n: (none, none, o), alive: true))
                stamp.append(0)
                if o != none && o < tris.count {
                    for k in 0..<3 {
                        let x = tris[o].vert((k + 1) % 3), y = tris[o].vert((k + 2) % 3)
                        if (x == b && y == a) || (x == a && y == b) { tris[o].setNb(k, base + i) }
                    }
                }
            }
            for (i, (a, b, _)) in rim.enumerated() {
                let acrossB = rim.firstIndex { $0.0 == b }.map { base + $0 } ?? none
                let acrossA = rim.firstIndex { $0.1 == a }.map { base + $0 } ?? none
                tris[base + i].n.0 = acrossB
                tris[base + i].n.1 = acrossA
            }
            last = base
            return pi
        }

        func edges() -> Set<Int64> {
            var e = Set<Int64>()
            for t in tris where t.alive {
                for k in 0..<3 {
                    let a = t.vert(k), b = t.vert((k + 1) % 3)
                    e.insert(PuppetKit.edgeKey(min(a, b), max(a, b)))
                }
            }
            return e
        }
    }

    @inline(__always) static func edgeKey(_ a: Int, _ b: Int) -> Int64 { Int64(a) << 32 | Int64(b) }

    /// Even-odd point-in-polygon test against closed outline segments, bucketed by row.
    struct Inside {
        let pts: [SIMD2<Double>]
        let segs: [(Int, Int)]
        let y0: Double
        let row: Double
        var rows: [[Int]]

        init(_ pts: [SIMD2<Double>], _ segs: [(Int, Int)], _ row: Double) {
            self.pts = pts; self.segs = segs; self.row = row
            var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
            for (a, b) in segs { lo = fmin(lo, fmin(pts[a].y, pts[b].y)); hi = fmax(hi, fmax(pts[a].y, pts[b].y)) }
            y0 = lo
            let n = hi >= lo ? Int(GeometryKit.clampR(((hi - lo) / row).rounded(.down), 0, 1e5)) + 1 : 0
            rows = [[Int]](repeating: [], count: n)
            for (i, (a, b)) in segs.enumerated() {
                let l = fmin(pts[a].y, pts[b].y), h = fmax(pts[a].y, pts[b].y)
                let r0 = Int(((l - lo) / row).rounded(.down)), r1 = Int(((h - lo) / row).rounded(.down))
                if r0 > r1 || r0 >= n { continue }
                for r in r0...min(r1, n - 1) { rows[r].append(i) }
            }
        }

        func contains(_ p: SIMD2<Double>) -> Bool {
            if p.y < y0 { return false }
            let ri = ((p.y - y0) / row).rounded(.down)
            guard ri >= 0, ri < Double(rows.count) else { return false }
            var odd = false
            for i in rows[Int(ri)] {
                let a = pts[segs[i].0], b = pts[segs[i].1]
                if (a.y > p.y) != (b.y > p.y) && p.x < a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x) { odd.toggle() }
            }
            return odd
        }
    }

    /// photocraft `build_mesh`.
    static func buildMesh(_ cov: Coverage, _ bounds: PixelRect, _ density: PuppetDensity, _ expansion: Double) -> PuppetMesh {
        if bounds.isEmpty { return PuppetMesh() }
        let e = expansion.isFinite ? GeometryKit.clampR(expansion, -200, 200) : 0
        // The density counts steps across the region the mesh covers (grown by the expansion).
        let long = Double(max(bounds.width, bounds.height)) + 2 * fmax(e, 0)
        let spacing = fmax(long / density.cells, 2)
        let field = Field(cov, bounds, e)
        let loops = field.outline()
        let empty = PuppetMesh(spacing: spacing)
        if loops.isEmpty { return empty }
        var tol = fmax(0.5 * field.g, 0.5)
        var rings: [[SIMD2<Double>]]
        while true {
            rings = loops.map { densify(simplify($0, tol), spacing) }
            if rings.reduce(0, { $0 + $1.count }) <= maxOutlinePoints || tol > spacing { break }
            tol *= 2
        }
        let lo = SIMD2(field.x0, field.y0), hi = SIMD2(field.x0 + Double(field.bw) * field.g, field.y0 + Double(field.bh) * field.g)
        var dl = Delaunay(lo, hi)
        var segs: [(Int, Int)] = []
        for ring in rings {
            let idx = ring.compactMap { dl.insert($0) }
            for (k, a) in idx.enumerated() {
                let b = idx[(k + 1) % idx.count]
                if a != b { segs.append((a, b)) }
            }
        }
        // The inside: a triangular lattice, kept half a step clear of the outline.
        let rise = spacing * 3.0.squareRoot() / 2
        let rows = Int(((hi.y - lo.y) / rise).rounded(.up)), cols = Int(((hi.x - lo.x) / spacing).rounded(.up))
        for j in 0...rows {
            for i in 0...cols {
                let p = SIMD2(lo.x + (Double(i) + 0.5 * Double(j % 2)) * spacing, lo.y + Double(j) * rise)
                if field.value(p) < -0.5 * spacing { _ = dl.insert(p) }
            }
        }
        // Recover the outline's sides: split a side the triangulation lacks at its midpoint.
        var budget = segs.count * 2
        for _ in 0..<8 {
            let edges = dl.edges()
            var next: [(Int, Int)] = []
            next.reserveCapacity(segs.count)
            var split = false
            for (a, b) in segs {
                if budget == 0 || edges.contains(edgeKey(min(a, b), max(a, b))) {
                    next.append((a, b))
                    continue
                }
                if let c = dl.insert(lerp(dl.pts[a], dl.pts[b], 0.5)), c != a && c != b {
                    next.append((a, c))
                    next.append((c, b))
                    budget -= 1
                    split = true
                } else {
                    next.append((a, b))
                }
            }
            segs = next
            if !split { break }
        }
        let inside = Inside(dl.pts, segs, spacing)
        var tris: [(Int, Int, Int)] = []
        for t in dl.tris where t.alive && t.v.0 >= 3 && t.v.1 >= 3 && t.v.2 >= 3 {
            let a = dl.pts[t.v.0], b = dl.pts[t.v.1], c = dl.pts[t.v.2]
            if orient(a, b, c) > 1e-9 && inside.contains(SIMD2((a.x + b.x + c.x) / 3, (a.y + b.y + c.y) / 3)) { tris.append(t.v) }
        }
        if tris.isEmpty { return empty }
        // Keep the vertices in use, numbered for a narrow band in the solver's matrix.
        let pos = dl.pts
        let order = bandOrder(pos, tris)
        var remap = [Int](repeating: Int.max, count: pos.count)
        for (new, old) in order.enumerated() { remap[old] = new }
        return PuppetMesh(verts: order.map { pos[$0] }, tris: tris.map { SIMD3(Int32(remap[$0.0]), Int32(remap[$0.1]), Int32(remap[$0.2])) }, spacing: spacing)
    }

    /// The vertices `tris` use, in reverse Cuthill–McKee order (breadth first from the topmost
    /// vertex of each piece, lower degrees first).
    static func bandOrder(_ pos: [SIMD2<Double>], _ tris: [(Int, Int, Int)]) -> [Int] {
        var adj = [[Int]](repeating: [], count: pos.count)
        for t in tris {
            let tv = [t.0, t.1, t.2]
            for k in 0..<3 {
                let a = tv[k], b = tv[(k + 1) % 3]
                adj[a].append(b)
                adj[b].append(a)
            }
        }
        for i in adj.indices {
            adj[i].sort()
            var dedup: [Int] = []
            for v in adj[i] where dedup.last != v { dedup.append(v) }
            adj[i] = dedup
        }
        // Stable sort by (y, x): ties keep index order.
        let starts = (0..<pos.count).filter { !adj[$0].isEmpty }.sorted { a, b in
            if pos[a].y != pos[b].y { return pos[a].y < pos[b].y }
            if pos[a].x != pos[b].x { return pos[a].x < pos[b].x }
            return a < b
        }
        var seen = [Bool](repeating: false, count: pos.count)
        var order: [Int] = []
        order.reserveCapacity(starts.count)
        for s in starts where !seen[s] {
            seen[s] = true
            var i = order.count
            order.append(s)
            while i < order.count {
                let v = order[i]
                i += 1
                // Stable by degree: ties keep the adjacency's ascending order.
                let next = adj[v].filter { !seen[$0] }.sorted { (adj[$0].count, $0) < (adj[$1].count, $1) }
                for w in next {
                    seen[w] = true
                    order.append(w)
                }
            }
        }
        order.reverse()
        return order
    }
}

// MARK: - Solver

extension PuppetKit {
    /// A compressed sparse row matrix (symmetric, used by CG).
    struct Csr {
        var rows: [Int]
        var cols: [Int]
        var vals: [Double]
        var diag: [Double]

        init(_ n: Int, _ t0: [(Int, Int, Double)]) {
            // Rust's stable sort by (i, j): duplicates sum in insertion order.
            let order = t0.indices.sorted { a, b in (t0[a].0, t0[a].1, a) < (t0[b].0, t0[b].1, b) }
            rows = [Int](repeating: 0, count: n + 1)
            cols = []
            vals = []
            cols.reserveCapacity(t0.count)
            vals.reserveCapacity(t0.count)
            var last = (Int.max, Int.max)
            for k in order {
                let (i, j, v) = t0[k]
                if (i, j) == last {
                    vals[vals.count - 1] += v
                    continue
                }
                last = (i, j)
                cols.append(j)
                vals.append(v)
                rows[i + 1] = cols.count
            }
            for i in 0..<n { rows[i + 1] = max(rows[i + 1], rows[i]) }
            diag = [Double](repeating: 1, count: n)
            for i in 0..<n {
                for k in rows[i]..<rows[i + 1] where cols[k] == i && vals[k] > 0 { diag[i] = vals[k] }
            }
        }

        func mul(_ x: [Double], _ out: inout [Double]) {
            for i in 0..<out.count {
                var s = 0.0
                for k in rows[i]..<rows[i + 1] { s += vals[k] * x[cols[k]] }
                out[i] = s
            }
        }

        /// Jacobi-preconditioned conjugate gradients, warm-started from `x`.
        func solve(_ b: [Double], _ x: inout [Double]) {
            let n = b.count
            var r = [Double](repeating: 0, count: n)
            mul(x, &r)
            for i in 0..<n { r[i] = b[i] - r[i] }
            var bs = 0.0
            for v in b { bs += v * v }
            let bn = fmax(bs.squareRoot(), 1e-30)
            var z = (0..<n).map { r[$0] / diag[$0] }
            var p = z
            var rz = 0.0
            for i in 0..<n { rz += r[i] * z[i] }
            var ap = [Double](repeating: 0, count: n)
            for _ in 0..<min(max(4 * n, 50), 2000) {
                var rr = 0.0
                for v in r { rr += v * v }
                if rr.squareRoot() <= 1e-12 * bn { break }
                mul(p, &ap)
                var pap = 0.0
                for i in 0..<n { pap += p[i] * ap[i] }
                if abs(pap) < 1e-300 { break }
                let alpha = rz / pap
                for i in 0..<n {
                    x[i] += alpha * p[i]
                    r[i] -= alpha * ap[i]
                }
                for i in 0..<n { z[i] = r[i] / diag[i] }
                var rz2 = 0.0
                for i in 0..<n { rz2 += r[i] * z[i] }
                let beta = rz2 / rz
                rz = rz2
                for i in 0..<n { p[i] = z[i] + beta * p[i] }
            }
        }
    }

    /// Banded Cholesky factor `A = L Lᵀ`, factored once per pin set.
    struct BandChol {
        let n: Int
        let p: Int
        /// Row `i` holds `L[i][i − p … i]`.
        var l: [Double]

        init?(_ a: Csr) {
            let n = a.diag.count
            var p = 0
            for i in 0..<n { for k in a.rows[i]..<a.rows[i + 1] { p = max(p, abs(i - a.cols[k])) } }
            if n.multipliedReportingOverflow(by: p + 1).partialValue > 40_000_000 { return nil }
            let w = p + 1
            var l = [Double](repeating: 0, count: n * w)
            for i in 0..<n { for k in a.rows[i]..<a.rows[i + 1] where a.cols[k] <= i { l[i * w + (a.cols[k] + p - i)] = a.vals[k] } }
            let ok = l.withUnsafeMutableBufferPointer { lp -> Bool in
                for i in 0..<n {
                    let lo = max(i - p, 0)
                    for j in lo...i {
                        let jlo = max(max(j - p, 0), lo)
                        var s = lp[i * w + (j + p - i)]
                        var k = jlo
                        while k < j { s -= lp[i * w + (k + p - i)] * lp[j * w + (k + p - j)]; k += 1 }
                        if i == j {
                            if s <= 0 || !s.isFinite { return false }
                            lp[i * w + p] = s.squareRoot()
                        } else {
                            lp[i * w + (j + p - i)] = s / lp[j * w + p]
                        }
                    }
                }
                return true
            }
            if !ok { return nil }
            self.n = n; self.p = p; self.l = l
        }

        func solve(_ b: [Double], _ x: inout [Double]) {
            let n = self.n, p = self.p, w = p + 1
            var y = b
            l.withUnsafeBufferPointer { lp in
                for i in 0..<n {
                    var s = y[i]
                    var k = max(i - p, 0)
                    while k < i { s -= lp[i * w + (k + p - i)] * y[k]; k += 1 }
                    y[i] = s / lp[i * w + p]
                }
                for i in Swift.stride(from: n - 1, through: 0, by: -1) {
                    var s = y[i]
                    var k = i + 1
                    let hi = min(i + p + 1, n)
                    while k < hi { s -= lp[k * w + (i + p - k)] * x[k]; k += 1 }
                    x[i] = s / lp[i * w + p]
                }
            }
        }
    }

    /// A pin bound to the mesh: barycentric weights on a triangle's vertices.
    struct Bound: Sendable {
        var verts: (Int, Int, Int)
        var bary: (Double, Double, Double)
        func v(_ k: Int) -> Int { k == 0 ? verts.0 : (k == 1 ? verts.1 : verts.2) }
        func b(_ k: Int) -> Double { k == 0 ? bary.0 : (k == 1 ? bary.1 : bary.2) }
    }

    /// Cotangent of the angle at `a`.
    static func cot(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        let u = SIMD2(b.x - a.x, b.y - a.y), v = SIMD2(c.x - a.x, c.y - a.y)
        let cross = abs(u.x * v.y - u.y * v.x)
        return cross < 1e-12 ? 0 : (u.x * v.x + u.y * v.y) / cross
    }

    static func locate(_ mesh: PuppetMesh, _ p: SIMD2<Double>) -> Bound {
        for t in mesh.tris {
            let a = mesh.verts[Int(t.x)], b = mesh.verts[Int(t.y)], c = mesh.verts[Int(t.z)]
            let det = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
            if abs(det) < 1e-12 { continue }
            let l1 = ((p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y)) / det
            let l2 = ((b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)) / det
            let l0 = 1 - l1 - l2
            if l0 >= -1e-9 && l1 >= -1e-9 && l2 >= -1e-9 { return Bound(verts: (Int(t.x), Int(t.y), Int(t.z)), bary: (l0, l1, l2)) }
        }
        // Outside the mesh: the nearest vertex (the first of equal ones).
        var best = 0, bd = Double.infinity
        for (i, v) in mesh.verts.enumerated() where dist2(v, p) < bd { bd = dist2(v, p); best = i }
        return Bound(verts: (best, best, best), bary: (1, 0, 0))
    }
}

/// Prepared ARAP solver for one mesh and a set of pin source positions (photocraft
/// `PuppetSolver`).
public struct PuppetSolver: Sendable {
    public let mesh: PuppetMesh
    /// Cotangent weight of each triangle's edges: `w[t][k]` for the edge opposite corner `k`.
    let w: [SIMD3<Double>]
    let bound: [PuppetKit.Bound]
    /// Triangles whose rotation a pin fixes, per pin.
    let pinTris: [[Int]]
    /// Vertices of components without pins (held at rest).
    let anchored: [Bool]
    let matrix: PuppetKit.Csr
    let chol: PuppetKit.BandChol?
    let pinWeight: Double

    /// Prepares the solver for pins placed at `pinSrc` (rotation-fixed pins flagged in
    /// `fixedRotation`).
    public init(mesh: PuppetMesh, pinSrc: [SIMD2<Double>], fixedRotation: [Bool]) {
        let nv = mesh.verts.count
        let tri = mesh.tris.map { (Int($0.x), Int($0.y), Int($0.z)) }
        w = tri.map { t in
            let a = mesh.verts[t.0], b = mesh.verts[t.1], c = mesh.verts[t.2]
            return SIMD3(0.5 * PuppetKit.cot(a, b, c), 0.5 * PuppetKit.cot(b, c, a), 0.5 * PuppetKit.cot(c, a, b))
        }
        // Without vertices there is nothing to bind a pin to (photocraft #951).
        let bound = nv == 0 ? [] : pinSrc.map { PuppetKit.locate(mesh, $0) }
        // Connected components (union-find over triangle edges).
        var parent = Array(0..<nv)
        func find(_ i0: Int) -> Int {
            var i = i0
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for t in tri {
            for k in 1..<3 {
                let a = find(t.0), b = find(k == 1 ? t.1 : t.2)
                if a != b { parent[a] = b }
            }
        }
        var pinnedRoot = [Bool](repeating: false, count: nv)
        for b in bound { for k in 0..<3 { pinnedRoot[find(b.v(k))] = true } }
        anchored = (0..<nv).map { !pinnedRoot[find($0)] }
        // Rotation-fixed pins: the triangles around the pin's nearest vertex.
        pinTris = bound.enumerated().map { k, b in
            if !(k < fixedRotation.count && fixedRotation[k]) { return [] }
            let p = pinSrc[k]
            var v = b.v(0)
            for j in 1..<3 where PuppetKit.dist2(mesh.verts[b.v(j)], p) < PuppetKit.dist2(mesh.verts[v], p) { v = b.v(j) }
            return tri.indices.filter { tri[$0].0 == v || tri[$0].1 == v || tri[$0].2 == v }
        }
        var trip: [(Int, Int, Double)] = []
        trip.reserveCapacity(tri.count * 12 + nv)
        var diagSum = 0.0
        for (t, wt) in zip(tri, w) {
            let tv = [t.0, t.1, t.2]
            for k in 0..<3 {
                let i = tv[(k + 1) % 3], j = tv[(k + 2) % 3]
                let wk = wt[k]
                trip.append((i, i, wk))
                trip.append((j, j, wk))
                trip.append((i, j, -wk))
                trip.append((j, i, -wk))
                diagSum += 2 * wk
            }
        }
        let pw = 1e4 * fmax(diagSum / Double(max(nv, 1)), 1)
        for b in bound { for a in 0..<3 { for c in 0..<3 { trip.append((b.v(a), b.v(c), pw * b.b(a) * b.b(c))) } } }
        for (v, an) in anchored.enumerated() where an { trip.append((v, v, pw)) }
        matrix = PuppetKit.Csr(nv, trip)
        chol = PuppetKit.BandChol(matrix)
        self.mesh = mesh
        self.bound = bound
        pinWeight = pw
    }

    var triIndices: [(Int, Int, Int)] { mesh.tris.map { (Int($0.x), Int($0.y), Int($0.z)) } }

    /// The ARAP energy of `v` for the given per-triangle linear maps (plus the pin terms).
    func energyWith(_ v: [SIMD2<Double>], _ rots: [SIMD4<Double>], _ pinDst: [SIMD2<Double>]) -> Double {
        let x = mesh.verts
        var e = 0.0
        for ((t, wt), r) in zip(zip(triIndices, w), rots) {
            let tv = [t.0, t.1, t.2]
            for k in 0..<3 {
                let i = tv[(k + 1) % 3], j = tv[(k + 2) % 3]
                let d = SIMD2(v[i].x - v[j].x, v[i].y - v[j].y)
                let ex = SIMD2(x[i].x - x[j].x, x[i].y - x[j].y)
                let re = SIMD2(r[0] * ex.x + r[1] * ex.y, r[2] * ex.x + r[3] * ex.y)
                let dx = d.x - re.x, dy = d.y - re.y
                e += wt[k] * (dx * dx + dy * dy)
            }
        }
        for (b, d) in zip(bound, pinDst) {
            var p = SIMD2<Double>(0, 0)
            for k in 0..<3 { p = SIMD2(p.x + b.b(k) * v[b.v(k)].x, p.y + b.b(k) * v[b.v(k)].y) }
            e += pinWeight * PuppetKit.dist2(p, d)
        }
        return e
    }

    func local(_ v: [SIMD2<Double>], _ mode: PuppetMode, _ fixed: [Double?]) -> [SIMD4<Double>] {
        let x = mesh.verts
        var rots: [SIMD4<Double>] = zip(triIndices, w).map { t, wt in
            var s = SIMD4<Double>(0, 0, 0, 0)
            var norm = 0.0
            let tv = [t.0, t.1, t.2]
            for k in 0..<3 {
                let i = tv[(k + 1) % 3], j = tv[(k + 2) % 3]
                let d = SIMD2(v[i].x - v[j].x, v[i].y - v[j].y)
                let e = SIMD2(x[i].x - x[j].x, x[i].y - x[j].y)
                s[0] += wt[k] * d.x * e.x
                s[1] += wt[k] * d.x * e.y
                s[2] += wt[k] * d.y * e.x
                s[3] += wt[k] * d.y * e.y
                norm += wt[k] * (e.x * e.x + e.y * e.y)
            }
            let c = s[0] + s[3], sn = s[2] - s[1]
            let th = atan2(sn, c)
            var scale: Double
            switch mode {
            case .rigid: scale = 1
            case .normal: scale = (hypot(c, sn) / fmax(norm, 1e-12)).squareRoot()
            case .distort: scale = hypot(c, sn) / fmax(norm, 1e-12)
            }
            if !(scale.isFinite && scale > 0) { scale = 1 }
            let sth = sin(th), cth = cos(th)
            return SIMD4(scale * cth, -scale * sth, scale * sth, scale * cth)
        }
        for (k, tris) in pinTris.enumerated() {
            if k < fixed.count, let deg = fixed[k] {
                let a = deg * (Double.pi / 180)
                let s = sin(a), c = cos(a)
                for t in tris { rots[t] = SIMD4(c, -s, s, c) }
            }
        }
        return rots
    }

    func global(_ rots: [SIMD4<Double>], _ pinDst: [SIMD2<Double>], _ v: inout [SIMD2<Double>]) {
        let nv = v.count
        let x = mesh.verts
        var bx = [Double](repeating: 0, count: nv), by = [Double](repeating: 0, count: nv)
        for ((t, wt), r) in zip(zip(triIndices, w), rots) {
            let tv = [t.0, t.1, t.2]
            for k in 0..<3 {
                let i = tv[(k + 1) % 3], j = tv[(k + 2) % 3]
                let e = SIMD2(x[i].x - x[j].x, x[i].y - x[j].y)
                let re = SIMD2(r[0] * e.x + r[1] * e.y, r[2] * e.x + r[3] * e.y)
                bx[i] += wt[k] * re.x
                by[i] += wt[k] * re.y
                bx[j] -= wt[k] * re.x
                by[j] -= wt[k] * re.y
            }
        }
        for (b, d) in zip(bound, pinDst) {
            for k in 0..<3 {
                bx[b.v(k)] += pinWeight * b.b(k) * d.x
                by[b.v(k)] += pinWeight * b.b(k) * d.y
            }
        }
        for (i, an) in anchored.enumerated() where an {
            bx[i] += pinWeight * x[i].x
            by[i] += pinWeight * x[i].y
        }
        var sx = v.map(\.x), sy = v.map(\.y)
        if let c = chol {
            c.solve(bx, &sx)
            c.solve(by, &sy)
        } else {
            matrix.solve(bx, &sx)
            matrix.solve(by, &sy)
        }
        for i in 0..<nv { v[i] = SIMD2(sx[i], sy[i]) }
    }

    /// Deforms the mesh: `pinDst` (one per pin given to `init`), optional fixed pin rotations
    /// (degrees), `iterations` local/global rounds, warm-started from `initial` when given.
    /// Returns the deformed vertices and the rigid ARAP energy after each round.
    public func solve(pinDst: [SIMD2<Double>], rotations: [Double?], mode: PuppetMode, iterations: Int, initial: [SIMD2<Double>]?) -> ([SIMD2<Double>], [Double]) {
        let nv = mesh.verts.count
        var v: [SIMD2<Double>]
        if let i = initial, i.count == nv { v = i } else { v = mesh.verts }
        if nv == 0 { return (v, []) }
        if initial == nil || initial!.count != nv {
            // Start from R = I, or with rotated pins, each triangle turned by the inverse-distance
            // weighted angle of the rotated pins.
            var rotated: [(SIMD2<Double>, Double)] = []
            for (b, r) in zip(bound, rotations) {
                guard let deg = r else { continue }
                var p = SIMD2<Double>(0, 0)
                for k in 0..<3 { p = SIMD2(p.x + b.b(k) * mesh.verts[b.v(k)].x, p.y + b.b(k) * mesh.verts[b.v(k)].y) }
                rotated.append((p, deg * (Double.pi / 180)))
            }
            let r: [SIMD4<Double>] = triIndices.map { t in
                if rotated.isEmpty { return SIMD4(1, 0, 0, 1) }
                var c = SIMD2<Double>(0, 0)
                for i in [t.0, t.1, t.2] { c = SIMD2(c.x + mesh.verts[i].x / 3, c.y + mesh.verts[i].y / 3) }
                var sw = 0.0, sa = 0.0
                for (p, a) in rotated {
                    let wgt = 1 / (PuppetKit.dist2(p, c) + 1)
                    sw += wgt
                    sa += wgt * a
                }
                let s = sin(sa / sw), co = cos(sa / sw)
                return SIMD4(co, -s, s, co)
            }
            global(r, pinDst, &v)
        }
        var energies: [Double] = []
        energies.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let rots = local(v, mode, rotations)
            global(rots, pinDst, &v)
            let rigid = local(v, .rigid, rotations)
            energies.append(energyWith(v, rigid, pinDst))
        }
        return (v, energies)
    }

    /// Energy of the current state with the rigid best fit (for monitoring).
    public func energy(_ v: [SIMD2<Double>], pinDst: [SIMD2<Double>], rotations: [Double?]) -> Double {
        energyWith(v, local(v, .rigid, rotations), pinDst)
    }

    /// Triangle draw order (back to front) for pins with depths.
    public func drawOrder(depths: [Int32], pinSrc: [SIMD2<Double>]) -> [Int] {
        let order = Array(0..<mesh.tris.count)
        if depths.allSatisfy({ $0 == 0 }) || pinSrc.isEmpty { return order }
        let d: [Int32] = order.map { t in
            let tv = mesh.tris[t]
            var c = SIMD2<Double>(0, 0)
            for i in [Int(tv.x), Int(tv.y), Int(tv.z)] { c = SIMD2(c.x + mesh.verts[i].x / 3, c.y + mesh.verts[i].y / 3) }
            var k = 0
            for j in 1..<pinSrc.count where PuppetKit.dist2(pinSrc[j], c) < PuppetKit.dist2(pinSrc[k], c) { k = j }
            return k < depths.count ? depths[k] : 0
        }
        // Rust's stable sort by depth.
        return order.sorted { (d[$0], $0) < (d[$1], $1) }
    }

    /// The bound pins' points on the deformed mesh.
    func pinPoints(_ v: [SIMD2<Double>]) -> [SIMD2<Double>] {
        bound.map { b in
            var p = SIMD2<Double>(0, 0)
            for k in 0..<3 { p = SIMD2(p.x + b.b(k) * v[b.v(k)].x, p.y + b.b(k) * v[b.v(k)].y) }
            return p
        }
    }
}
