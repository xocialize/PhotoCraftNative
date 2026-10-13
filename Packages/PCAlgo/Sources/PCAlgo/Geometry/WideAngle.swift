// Port of photocraft-algo (crates/algo/src/wideangle.rs; photo_util.rs: SparseLs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Adaptive Wide Angle: straighten lines a wide-angle or fisheye lens bends. Constraints
// are marked by their end points; the lens model (equidistant fisheye r = f·θ, rectilinear
// r = f·tan θ, or a full 2:1 equirectangular sphere) turns them into rays, and the scene line is
// the great circle through both, sampled back into the image as the curve the user sees. A
// content-preserving mesh warp then makes every constrained curve straight (and level or plumb
// when asked) while keeping each triangle as similar as possible to its original shape:
// Igarashi, Moscovich & Hughes, As-Rigid-As-Possible Shape Manipulation (SIGGRAPH 2005), as used
// by Carroll, Agrawala & Agarwala, Optimizing Content-Preserving Projections for Wide-Angle
// Images (SIGGRAPH 2009). The least-squares problems are solved with conjugate gradients (CGLS)
// on the CPU; the result is rendered by textured triangles (`MeshWarp.warpTriangles`, sampled on
// the GPU).

import Foundation
import PCFoundation

/// Lens projection of the source image (photocraft `WideModel`).
public enum WideModel: String, Codable, Sendable, Hashable, CaseIterable {
    case auto, fisheye, perspective, fullSpherical

    /// photocraft `WideModel::parse` ("auto", "fisheye", "perspective", "fullSpherical"/"spherical").
    public init?(parsing s: String) {
        switch s {
        case "auto": self = .auto
        case "fisheye": self = .fisheye
        case "perspective": self = .perspective
        case "fullSpherical", "spherical": self = .fullSpherical
        default: return nil
        }
    }
}

/// Adaptive Wide Angle settings (photocraft `WideAngle`; camelCase serde names, every field
/// defaulted).
public struct WideAngle: Hashable, Sendable, Codable {
    /// Constraint orientation (photocraft `Orientation`).
    public enum Orientation: String, Codable, Sendable, Hashable, CaseIterable {
        case free, horizontal, vertical
    }

    /// A constraint: the end points of a scene line, image px (photocraft `Constraint`).
    public struct Constraint: Hashable, Sendable, Codable {
        public var a: SIMD2<Double>
        public var b: SIMD2<Double>
        public var orientation: Orientation
        public init(a: SIMD2<Double>, b: SIMD2<Double>, orientation: Orientation = .free) { self.a = a; self.b = b; self.orientation = orientation }

        enum CodingKeys: String, CodingKey { case a, b, orientation }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            a = try c.decode(SIMD2<Double>.self, forKey: .a)
            b = try c.decode(SIMD2<Double>.self, forKey: .b)
            orientation = try c.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .free
        }
    }

    public var model: WideModel
    /// Focal length in mm (35 mm frame after the crop factor); 0 picks a default.
    public var focalLength: Double
    public var cropFactor: Double
    /// Output scale in percent.
    public var scale: Double
    public var constraints: [Constraint]

    public init(model: WideModel = .auto, focalLength: Double = 0, cropFactor: Double = 1, scale: Double = 100, constraints: [Constraint] = []) {
        self.model = model; self.focalLength = focalLength; self.cropFactor = cropFactor; self.scale = scale; self.constraints = constraints
    }

    enum CodingKeys: String, CodingKey { case model, focalLength, cropFactor, scale, constraints }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(WideModel.self, forKey: .model) ?? .auto
        focalLength = try c.decodeIfPresent(Double.self, forKey: .focalLength) ?? 0
        cropFactor = try c.decodeIfPresent(Double.self, forKey: .cropFactor) ?? 1
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 100
        constraints = try c.decodeIfPresent([Constraint].self, forKey: .constraints) ?? []
    }

    /// Camera model over an image frame (photocraft `Camera`).
    public struct Camera: Hashable, Sendable {
        public var model: WideModel
        /// Focal length in px.
        public var f: Double
        public var c: SIMD2<Double>
        public var size: SIMD2<Double>

        /// Resolves `auto` and the focal length: 35 mm-equivalent `focal × crop` over a 36 mm long
        /// side; 0 picks a default (fisheye 12 mm, perspective 24 mm).
        public init(_ p: WideAngle, frame: PixelRect) {
            let w = Double(max(frame.width, 1)), h = Double(max(frame.height, 1))
            var f35 = p.focalLength * fmax(p.cropFactor, 0.1)
            let model: WideModel
            switch p.model {
            case .auto: model = abs(w / h - 2) < 0.01 ? .fullSpherical : (f35 > 0 && f35 < 17 ? .fisheye : .perspective)
            default: model = p.model
            }
            if !(f35 > 0) { f35 = model == .fisheye ? 12 : 24 }
            self.model = model
            f = f35 / 36 * max(w, h)
            c = SIMD2(Double(frame.x0 + frame.x1) / 2, Double(frame.y0 + frame.y1) / 2)
            size = SIMD2(w, h)
        }

        /// Image px → unit ray (x right, y down, z forward).
        public func ray(_ x: Double, _ y: Double) -> SIMD3<Double> {
            let dx = x - c.x, dy = y - c.y
            let v: SIMD3<Double>
            switch model {
            case .fullSpherical:
                let lon = dx / size.x * (2 * Double.pi)
                let lat = dy / size.y * Double.pi
                v = SIMD3(sin(lon) * cos(lat), sin(lat), cos(lon) * cos(lat))
            case .fisheye:
                let r = hypot(dx, dy)
                let th = r / f
                v = r < 1e-12 ? SIMD3(0, 0, 1) : SIMD3(sin(th) * dx / r, sin(th) * dy / r, cos(th))
            default:
                v = SIMD3(dx, dy, f)
            }
            return WideKit.norm(v)
        }

        /// Unit ray → image px.
        public func pixel(_ d: SIMD3<Double>) -> SIMD2<Double>? {
            switch model {
            case .fullSpherical:
                let lon = atan2(d.x, d.z)
                let lat = asin(GeometryKit.clampR(d.y, -1, 1))
                return SIMD2(c.x + lon / (2 * Double.pi) * size.x, c.y + lat / Double.pi * size.y)
            case .fisheye:
                let th = acos(GeometryKit.clampR(d.z, -1, 1))
                let s = hypot(d.x, d.y)
                if s < 1e-12 { return c }
                return SIMD2(c.x + f * th * d.x / s, c.y + f * th * d.y / s)
            default:
                return d.z > 1e-6 ? SIMD2(c.x + f * d.x / d.z, c.y + f * d.y / d.z) : nil
            }
        }

        /// `n + 1` image points along the scene line (great circle) from `a` to `b`.
        public func arc(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ n: Int) -> [SIMD2<Double>] {
            let da = ray(a.x, a.y), db = ray(b.x, b.y)
            let omega = acos(GeometryKit.clampR(WideKit.dot(da, db), -1, 1))
            return (0...n).compactMap { k in
                let t = Double(k) / Double(n)
                let d: SIMD3<Double>
                if omega < 1e-9 {
                    d = da
                } else {
                    let sa = sin((1 - t) * omega) / sin(omega), sb = sin(t * omega) / sin(omega)
                    d = WideKit.norm(SIMD3(sa * da.x + sb * db.x, sa * da.y + sb * db.y, sa * da.z + sb * db.z))
                }
                return pixel(d)
            }
        }
    }

    /// Solves the content-preserving warp over `frame` (photocraft `solve`).
    public func solve(frame: PixelRect) -> WideMesh { WideKit.solve(self, frame) }

    /// Applies Adaptive Wide Angle to `src` over `frame`: pixels outside the warped image become
    /// transparent (photocraft `apply`). The result has `src`'s format with alpha.
    public func apply(_ src: Surface, frame: PixelRect, interp: Interp = .bicubic, on backend: Backend = .auto) -> Surface {
        let mesh = solve(frame: frame)
        return MeshWarp.warpTriangles(src, srcRect: frame, verts: mesh.vertices, tris: mesh.triangles(), interp: interp, on: backend)
    }

    /// `apply` on a dense image (0 outside it): the result covers the warped mesh's bounds, alpha
    /// appended when `context` has none.
    public func apply(_ img: FloatImage, frame: PixelRect? = nil, interp: Interp = .bicubic, context: FilterContext? = nil,
                      on backend: Backend = .auto) throws -> FloatImage {
        let fr = frame ?? img.rect
        let mesh = solve(frame: fr)
        return try MeshWarp.warpTriangles(img, srcRect: fr, verts: mesh.vertices, tris: mesh.triangles(), interp: interp, context: context, on: backend)
    }
}

/// The solved warp: a grid over the frame with each vertex's output position (photocraft
/// `WideMesh`).
public struct WideMesh: Hashable, Sendable {
    public var nx: Int
    public var ny: Int
    /// `(output, source)` per vertex, row-major `(nx + 1) × (ny + 1)`.
    public var verts: [MeshWarp.Vertex]
    /// Each constraint's curve in the source (for overlays).
    public var curves: [[SIMD2<Double>]]
    /// Max deviation from straight of the constrained curves after the warp (px).
    public var residual: Double

    var vertices: [MeshWarp.Vertex] { verts }

    public func triangles() -> [SIMD3<Int32>] {
        let w1 = nx + 1
        var t: [SIMD3<Int32>] = []
        t.reserveCapacity(nx * ny * 2)
        for j in 0..<ny {
            for i in 0..<nx {
                let a = Int32(j * w1 + i), w = Int32(w1)
                t.append(SIMD3(a, a + 1, a + w + 1))
                t.append(SIMD3(a, a + w + 1, a + w))
            }
        }
        return t
    }

    /// Output position of source point `p` (bilinear in its grid cell).
    public func map(frame: PixelRect, _ p: SIMD2<Double>) -> SIMD2<Double> {
        let cw = Double(frame.width) / Double(nx), ch = Double(frame.height) / Double(ny)
        let gx = GeometryKit.clampR((p.x - Double(frame.x0)) / cw, 0, Double(nx) - 1e-9)
        let gy = GeometryKit.clampR((p.y - Double(frame.y0)) / ch, 0, Double(ny) - 1e-9)
        let i = Int(gx.rounded(.down)), j = Int(gy.rounded(.down))
        let tx = gx - Double(i), ty = gy - Double(j)
        let w1 = nx + 1
        let a = verts[j * w1 + i].dst, b = verts[j * w1 + i + 1].dst, c = verts[(j + 1) * w1 + i].dst, d = verts[(j + 1) * w1 + i + 1].dst
        return SIMD2((a.x * (1 - tx) + b.x * tx) * (1 - ty) + (c.x * (1 - tx) + d.x * tx) * ty,
                     (a.y * (1 - tx) + b.y * tx) * (1 - ty) + (c.y * (1 - tx) + d.y * tx) * ty)
    }
}

enum WideKit {
    @inline(__always) static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    static func norm(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = fmax(dot(v, v).squareRoot(), 1e-300)
        return SIMD3(v.x / l, v.y / l, v.z / l)
    }

    static func solve(_ p: WideAngle, _ frame: PixelRect) -> WideMesh {
        let cam = WideAngle.Camera(p, frame: frame)
        let fw = Double(max(frame.width, 1)), fh = Double(max(frame.height, 1))
        let cells = 48.0
        let cell = max(fw, fh) / cells
        let nx = min(max(Int((fw / cell).rounded()), 2), 96)
        let ny = min(max(Int((fh / cell).rounded()), 2), 96)
        let cw = fw / Double(nx), ch = fh / Double(ny)
        let w1 = nx + 1
        let nv = w1 * (ny + 1)
        let src: [SIMD2<Double>] = (0..<nv).map { k in SIMD2(Double(frame.x0) + Double(k % w1) * cw, Double(frame.y0) + Double(k / w1) * ch) }
        let curves: [[SIMD2<Double>]] = p.constraints.map { cam.arc($0.a, $0.b, 24) }
        var x: [Double] = src.flatMap { [$0.x, $0.y] }
        // Bilinear weights of a source point in the grid.
        func weights(_ q: SIMD2<Double>) -> [(Int, Double)] {
            let gx = GeometryKit.clampR((q.x - Double(frame.x0)) / cw, 0, Double(nx) - 1e-9)
            let gy = GeometryKit.clampR((q.y - Double(frame.y0)) / ch, 0, Double(ny) - 1e-9)
            let i = Int(gx.rounded(.down)), j = Int(gy.rounded(.down))
            let tx = gx - Double(i), ty = gy - Double(j)
            let a = j * w1 + i
            return [(a, (1 - tx) * (1 - ty)), (a + 1, tx * (1 - ty)), (a + w1, (1 - tx) * ty), (a + w1 + 1, tx * ty)]
        }
        var tris: [(Int, Int, Int)] = []
        for j in 0..<ny {
            for i in 0..<nx {
                let a = j * w1 + i
                tris.append((a, a + 1, a + w1 + 1))
                tris.append((a, a + w1 + 1, a + w1))
                // Both diagonals so the shape term is symmetric.
                tris.append((a, a + 1, a + w1))
                tris.append((a + 1, a + w1 + 1, a + w1))
            }
        }
        let active = curves.indices.filter { curves[$0].count >= 3 }
        if !active.isEmpty {
            var normals: [SIMD2<Double>] = active.map { _ in SIMD2(0, 1) }
            for round in 0..<4 {
                var ls = SparseLs(n: 2 * nv)
                // Shape: v0 = v1 + u (v2 − v1) + v R90 (v2 − v1), with (u, v) from the source.
                for t in tris {
                    let tv = [t.0, t.1, t.2]
                    for rot in 0..<3 {
                        let i0 = tv[rot], i1 = tv[(rot + 1) % 3], i2 = tv[(rot + 2) % 3]
                        let p0 = src[i0], p1 = src[i1], p2 = src[i2]
                        let e = SIMD2(p2.x - p1.x, p2.y - p1.y)
                        let l2 = e.x * e.x + e.y * e.y
                        let d = SIMD2(p0.x - p1.x, p0.y - p1.y)
                        let u = (d.x * e.x + d.y * e.y) / l2
                        let v = (d.x * -e.y + d.y * e.x) / l2
                        ls.add([(2 * i0, 1), (2 * i1, -1 + u), (2 * i2, -u), (2 * i2 + 1, v), (2 * i1 + 1, -v)], 0, 1)
                        ls.add([(2 * i0 + 1, 1), (2 * i1 + 1, -1 + u), (2 * i2 + 1, -u), (2 * i2, -v), (2 * i1, v)], 0, 1)
                    }
                }
                // Weak anchoring to the source (fixes the global similarity).
                for (k, s) in src.enumerated() {
                    ls.add([(2 * k, 1)], s.x, 0.02)
                    ls.add([(2 * k + 1, 1)], s.y, 0.02)
                }
                // Lines.
                for (ci, k) in active.enumerated() {
                    let c = curves[k]
                    let n: SIMD2<Double>
                    switch p.constraints[k].orientation {
                    case .horizontal: n = SIMD2(0, 1)
                    case .vertical: n = SIMD2(1, 0)
                    case .free: n = normals[ci]
                    }
                    let w0 = weights(c[0])
                    for q in c[1...] {
                        var row: [(Int, Double)] = []
                        row.reserveCapacity(16)
                        for (i, w) in weights(q) { row.append((2 * i, n.x * w)); row.append((2 * i + 1, n.y * w)) }
                        for (i, w) in w0 { row.append((2 * i, -n.x * w)); row.append((2 * i + 1, -n.y * w)) }
                        ls.add(row, 0, 10)
                    }
                }
                x = ls.solve(x, iterations: 400 + 200 * round)
                // Re-estimate free normals from the current end points.
                func pos(_ q: SIMD2<Double>) -> SIMD2<Double> {
                    var acc = SIMD2<Double>(0, 0)
                    for (i, w) in weights(q) { acc = SIMD2(acc.x + w * x[2 * i], acc.y + w * x[2 * i + 1]) }
                    return acc
                }
                var changed = false
                for (ci, k) in active.enumerated() {
                    let c = curves[k]
                    let a = pos(c[0]), b = pos(c[c.count - 1])
                    let d = SIMD2(b.x - a.x, b.y - a.y)
                    let l = fmax(hypot(d.x, d.y), 1e-9)
                    let nn = SIMD2(-d.y / l, d.x / l)
                    if abs(nn.x - normals[ci].x) + abs(nn.y - normals[ci].y) > 1e-3 { changed = true }
                    normals[ci] = nn
                }
                if round == 0 && active.allSatisfy({ p.constraints[$0].orientation != .free }) { break }
                if round > 0 && !changed { break }
            }
        }
        // Scale about the centre.
        let s = GeometryKit.clampR(p.scale / 100, 0.1, 10)
        let c = cam.c
        let verts = (0..<nv).map { k in MeshWarp.Vertex(dst: SIMD2(c.x + (x[2 * k] - c.x) * s, c.y + (x[2 * k + 1] - c.y) * s), src: src[k]) }
        var mesh = WideMesh(nx: nx, ny: ny, verts: verts, curves: curves, residual: 0)
        // Straightness residual: distance of curve samples from the chord of their mapped ends.
        var worst = 0.0
        for cv in mesh.curves where cv.count >= 3 {
            let pts = cv.map { mesh.map(frame: frame, $0) }
            let a = pts[0], b = pts[pts.count - 1]
            let d = SIMD2(b.x - a.x, b.y - a.y)
            let l = fmax(hypot(d.x, d.y), 1e-9)
            for q in pts { worst = fmax(worst, abs((q.x - a.x) * d.y - (q.y - a.y) * d.x) / l) }
        }
        mesh.residual = worst
        return mesh
    }
}

/// A sparse least-squares problem `min Σ w²(row·x − rhs)²` solved by conjugate gradients on the
/// normal equations (CGLS), photocraft `photo_util::SparseLs`. Rows are stored flat; `Aᵀv` runs per
/// unknown over its rows in row order (the same sums as photocraft's row-order scatter), so the
/// result is bit-identical and the products run in parallel.
struct SparseLs {
    let n: Int
    var rowStart: [Int] = [0]
    var cols: [Int32] = []
    var coefs: [Double] = []
    var rhs: [Double] = []

    init(n: Int) { self.n = n }

    mutating func add(_ row: [(Int, Double)], _ b: Double, _ w: Double) {
        for (i, c) in row { cols.append(Int32(i)); coefs.append(c * w) }
        rowStart.append(cols.count)
        rhs.append(b * w)
    }

    /// CGLS from `x0`; at most `iterations` iterations.
    func solve(_ x0: [Double], iterations: Int) -> [Double] {
        let m = rhs.count
        var x = x0
        // Aᵀ as per-unknown lists of (row, coefficient) in row order.
        var colStart = [Int](repeating: 0, count: n + 1)
        for c in cols { colStart[Int(c) + 1] += 1 }
        for i in 0..<n { colStart[i + 1] += colStart[i] }
        var fill = colStart
        var tRow = [Int32](repeating: 0, count: cols.count), tCoef = [Double](repeating: 0, count: cols.count)
        for r in 0..<m {
            for k in rowStart[r]..<rowStart[r + 1] {
                let c = Int(cols[k])
                tRow[fill[c]] = Int32(r); tCoef[fill[c]] = coefs[k]; fill[c] += 1
            }
        }
        func ax(_ v: [Double], _ out: inout [Double]) {
            v.withUnsafeBufferPointer { vp in
                out.withUnsafeMutableBufferPointer { op in
                    let o = UnsafeSendable(op)
                    rowStart.withUnsafeBufferPointer { rs in cols.withUnsafeBufferPointer { cs in coefs.withUnsafeBufferPointer { cf in
                        parallelChunks(m, minChunk: 4096) { range in
                            for r in range {
                                var s = 0.0
                                var k = rs[r]
                                while k < rs[r + 1] { s += cf[k] * vp[Int(cs[k])]; k += 1 }
                                o.value[r] = s
                            }
                        }
                    } } }
                }
            }
        }
        func atv(_ v: [Double], _ out: inout [Double]) {
            v.withUnsafeBufferPointer { vp in
                out.withUnsafeMutableBufferPointer { op in
                    let o = UnsafeSendable(op)
                    colStart.withUnsafeBufferPointer { cs in tRow.withUnsafeBufferPointer { tr in tCoef.withUnsafeBufferPointer { tc in
                        parallelChunks(n, minChunk: 2048) { range in
                            for i in range {
                                var s = 0.0
                                var k = cs[i]
                                while k < cs[i + 1] { s += tc[k] * vp[Int(tr[k])]; k += 1 }
                                o.value[i] = s
                            }
                        }
                    } } }
                }
            }
        }
        func sumSq(_ v: [Double]) -> Double { v.withUnsafeBufferPointer { p in var s = 0.0; var i = 0; while i < p.count { s += p[i] * p[i]; i += 1 }; return s } }
        var axv = [Double](repeating: 0, count: m)
        ax(x, &axv)
        var r = (0..<m).map { rhs[$0] - axv[$0] }
        var s = [Double](repeating: 0, count: n)
        atv(r, &s)
        var p = s
        var gamma = sumSq(s)
        let g0 = fmax(gamma, 1e-30)
        var q = [Double](repeating: 0, count: m)
        for _ in 0..<iterations {
            if gamma <= g0 * 1e-20 { break }
            ax(p, &q)
            let qq = sumSq(q)
            if qq <= 1e-300 { break }
            let alpha = gamma / qq
            x.withUnsafeMutableBufferPointer { xp in p.withUnsafeBufferPointer { pp in
                var i = 0
                while i < n { xp[i] += alpha * pp[i]; i += 1 }
            } }
            r.withUnsafeMutableBufferPointer { rp in q.withUnsafeBufferPointer { qp in
                var i = 0
                while i < m { rp[i] -= alpha * qp[i]; i += 1 }
            } }
            atv(r, &s)
            let g1 = sumSq(s)
            let beta = g1 / gamma
            gamma = g1
            p.withUnsafeMutableBufferPointer { pp in s.withUnsafeBufferPointer { sp in
                var i = 0
                while i < n { pp[i] = sp[i] + beta * pp[i]; i += 1 }
            } }
        }
        return x
    }
}
