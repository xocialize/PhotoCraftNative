// Port of photocraft-algo (crates/algo/src/warp.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Mesh warps (Edit › Transform › Warp, smart-object warps, Perspective Warp): resampling through any
// forward map. The source rectangle is cut into ≤ 512 × 512 cells of ~4 px whose vertices are mapped
// forward; each cell's two triangles are rasterised in destination space (f64 barycentrics, later
// triangles over earlier ones) with the source position interpolated, then the source is sampled
// there (premultiplied nearest / bilinear / Catmull-Rom), or, where the warp shrinks, averaged over
// a grid of bilinear subsamples covering the pixel's source footprint. Affine maps (the identity
// included) are reproduced exactly. The Metal path keeps the rasterisation on the CPU (exact
// coverage and depth order) and runs the sampling — the expensive part — per pixel on the GPU.

import CoreGraphics
import Foundation
import PCFoundation

/// Mesh warps (photocraft `warp.rs` functions).
public enum MeshWarp {
    /// A mesh vertex: where it lands (`dst`) and where it samples (`src`), document pixels.
    public struct Vertex: Hashable, Sendable, Codable {
        public var dst: SIMD2<Double>
        public var src: SIMD2<Double>
        public init(dst: SIMD2<Double>, src: SIMD2<Double>) { self.dst = dst; self.src = src }
    }

    /// Warps the content of `src` inside `srcRect` through the forward map `map` (source document
    /// coordinates → destination). Output has `src`'s format with alpha added; pixels outside the
    /// warped area are transparent (photocraft `warp_mesh_surface`). The surface-level calls never
    /// fail: `.auto`/`.gpu` fall back to the tiled CPU path when the GPU can't take the job.
    public static func warpMeshSurface(_ src: Surface, srcRect: PixelRect, map: (Double, Double) -> (Double, Double),
                                       interp: Interp = .bicubic, on backend: Backend = .auto) -> Surface {
        if srcRect.isEmpty { return Surface(format: src.format.with(alpha: true)) }
        let (verts, tris) = meshVertices(srcRect: srcRect, map: map)
        return warpTriangles(src, srcRect: srcRect, verts: verts, tris: tris, interp: interp, on: backend)
    }

    /// Rasterises textured triangles: each triangle samples `src` (restricted to `srcRect`) through
    /// the barycentric interpolation of its vertices' source positions; later triangles draw over
    /// earlier ones. Output has `src`'s format with alpha added (photocraft `warp_triangles`).
    public static func warpTriangles(_ src: Surface, srcRect: PixelRect, verts: [Vertex], tris: [SIMD3<Int32>], interp: Interp = .bicubic,
                                     on backend: Backend = .auto) -> Surface {
        MeshKit.warpTrianglesSurface(src, srcRect: srcRect, verts: verts, tris: tris, interp: interp, backend: backend)
    }

    /// `warpMeshSurface` for single-channel surfaces whose outside reads as their default value
    /// (layer masks, selections): the content is warped with alpha and flattened back onto the
    /// default (photocraft `warp_mesh_gray`).
    public static func warpMeshGray(_ s: Surface, map: (Double, Double) -> (Double, Double), interp: Interp = .bicubic,
                                    on backend: Backend = .auto) -> Surface {
        let def = s.defaultPixelValue.first ?? 0
        let fmt = s.format
        let src = ResampleKit.contentBounds(s)
        var out = Surface(format: fmt, defaultPixel: [def])
        if src.isEmpty { return out }
        var tmp = Surface(format: fmt.with(alpha: true))
        let v = s.readRegion(src)
        tmp.writeRegion(src, v.flatMap { [$0, 1] })
        let w = warpMeshSurface(tmp, srcRect: src, map: map, interp: interp, on: backend)
        // Clear the old region and write the warped one separately: one dense `src ∪ warped`
        // buffer grows with the square of how far a mesh moves the content (photocraft #995).
        out.writeRegion(src, [Float](repeating: def, count: src.area))
        let b = ResampleKit.contentBounds(w)
        if !b.isEmpty {
            let px = w.readRegion(b)
            out.writeRegion(b, (0..<b.area).map { px[2 * $0] * px[2 * $0 + 1] + def * (1 - px[2 * $0 + 1]) })
        }
        ResampleKit.prune(&out)
        return out
    }

    /// Places a smart object's source image (`src`, its pixels in `srcRect`) in the document:
    /// through `warp` (source space; nil for none/identity) and then the affine `t` (source →
    /// document) in one resampling pass, an exact shift for whole-pixel translations, bicubic
    /// otherwise (photocraft `place_source`; `t` uses photocraft's `Affine` convention, x' = a·u +
    /// c·v + tx, y' = b·u + d·v + ty, as `CGAffineTransform` does).
    public static func placeSource(_ src: Surface, srcRect: PixelRect, transform t: CGAffineTransform,
                                   warp: ((Double, Double) -> (Double, Double))? = nil, on backend: Backend = .auto) -> Surface {
        let (a, b, c, d, e, f) = (Double(t.a), Double(t.b), Double(t.c), Double(t.d), Double(t.tx), Double(t.ty))
        if let w = warp {
            return warpMeshSurface(src, srcRect: srcRect, map: { x, y in
                let (u, v) = w(x, y)
                return (a * u + c * v + e, b * u + d * v + f)
            }, interp: .bicubic, on: backend)
        }
        func near(_ x: Double, _ y: Double) -> Bool { abs(x - y) < 1e-9 }
        if near(a, 1) && near(b, 0) && near(c, 0) && near(d, 1) && near(e, e.rounded()) && near(f, f.rounded()) {
            return Resample.translateSurface(src, dx: ResampleKit.i32(e.rounded()), dy: ResampleKit.i32(f.rounded()))
        }
        return Transform.warpSurface(src, srcRect: srcRect, h: Homography([a, c, e, b, d, f, 0, 0, 1]), interp: .bicubic, on: backend)
    }

    /// `placeSource` through a projective map `h` (source → document; Distort, Perspective): the
    /// warp first (in source space), then `h` (photocraft `place_source_projective`).
    public static func placeSourceProjective(_ src: Surface, srcRect: PixelRect, h: Homography,
                                             warp: ((Double, Double) -> (Double, Double))? = nil, on backend: Backend = .auto) -> Surface {
        if let w = warp {
            return warpMeshSurface(src, srcRect: srcRect, map: { x, y in
                let (u, v) = w(x, y)
                return h.apply(u, v)
            }, interp: .bicubic, on: backend)
        }
        return Transform.warpSurface(src, srcRect: srcRect, h: h, interp: .bicubic, on: backend)
    }

    /// `warpMeshSurface` on a dense image (0 outside it), sampling inside `srcRect` (default: the
    /// image). The result covers the mapped mesh's bounds plus a pixel, alpha appended when
    /// `context` has none; the same pixels as the surface call over that rectangle.
    public static func warpMesh(_ src: FloatImage, srcRect: PixelRect? = nil, map: (Double, Double) -> (Double, Double), interp: Interp = .bicubic,
                                context: FilterContext? = nil, on backend: Backend = .auto) throws -> FloatImage {
        let sr = srcRect ?? src.rect
        if sr.isEmpty { return FloatImage(rect: .empty, channels: src.channels + ((context?.alpha ?? FilterContext.inferred(channels: src.channels, bounds: src.rect).alpha) ? 0 : 1)) }
        let (verts, tris) = meshVertices(srcRect: sr, map: map)
        return try warpTriangles(src, srcRect: sr, verts: verts, tris: tris, interp: interp, context: context, on: backend)
    }

    /// `warpTriangles` on a dense image (see `warpMesh`).
    public static func warpTriangles(_ src: FloatImage, srcRect: PixelRect? = nil, verts: [Vertex], tris: [SIMD3<Int32>], interp: Interp = .bicubic,
                                     context: FilterContext? = nil, on backend: Backend = .auto) throws -> FloatImage {
        let ctx = context ?? FilterContext.inferred(channels: src.channels, bounds: src.rect)
        let (img, actx) = TransformKit.withAlpha(src, ctx)
        let sr = srcRect ?? src.rect
        guard !sr.isEmpty, let prep = MeshKit.prepare(verts: verts, tris: tris) else { return FloatImage(rect: .empty, channels: img.channels) }
        return try MeshKit.run(img, prep, srcRect: sr, interp: interp, ctx: actx, backend: backend)
    }

    /// The forward-mapped vertex grid and its triangles over `srcRect` (photocraft
    /// `warp_mesh_surface`'s mesh: cells of ~4 source px, at most 512 per axis).
    public static func meshVertices(srcRect: PixelRect, map: (Double, Double) -> (Double, Double)) -> ([Vertex], [SIMD3<Int32>]) {
        let sw = Double(srcRect.width), sh = Double(srcRect.height)
        let nx = min(max(Int((sw / MeshKit.cell).rounded(.up)), 1), MeshKit.maxCells)
        let ny = min(max(Int((sh / MeshKit.cell).rounded(.up)), 1), MeshKit.maxCells)
        var verts: [Vertex] = []
        verts.reserveCapacity((nx + 1) * (ny + 1))
        for j in 0...ny {
            for i in 0...nx {
                let sx = Double(srcRect.x0) + sw * Double(i) / Double(nx)
                let sy = Double(srcRect.y0) + sh * Double(j) / Double(ny)
                let (dx, dy) = map(sx, sy)
                verts.append(Vertex(dst: SIMD2(dx, dy), src: SIMD2(sx, sy)))
            }
        }
        let w1 = nx + 1
        var tris: [SIMD3<Int32>] = []
        tris.reserveCapacity(nx * ny * 2)
        for j in 0..<ny {
            for i in 0..<nx {
                let a = Int32(j * w1 + i), w = Int32(w1)
                tris.append(SIMD3(a, a + 1, a + w + 1))
                tris.append(SIMD3(a, a + w + 1, a + w))
            }
        }
        return (verts, tris)
    }
}

enum MeshKit {
    /// Grid cell size (source px) used to approximate the map.
    static let cell = 4.0
    /// Most cells along one axis (bounds memory and time on huge layers).
    static let maxCells = 512
    /// Most subsamples per axis when a warp shrinks the source; also the longest source step per
    /// destination pixel the filter follows (bounds the footprint each tile reads).
    static let maxSS = 8.0

    /// Triangles binned per destination tile.
    struct Prepared: Sendable, Codable {
        var verts: [MeshWarp.Vertex]
        var tris: [SIMD3<Int32>]
        var dst: PixelRect
        var tiles: [PixelRect]
        /// Triangle indices per tile, in depth order.
        var bins: [[Int32]]
    }

    /// Per triangle: its source step per destination pixel along x and y (`[dx_u, dx_v, dy_u,
    /// dy_v]`, the inverse map's Jacobian, constant over a triangle; zero when point-sampled) and
    /// the subsamples along each.
    struct TriInfo: Sendable, Codable {
        var j: SIMD4<Double>
        var nx: Int
        var ny: Int
    }

    /// The destination and the per-tile bins (photocraft `warp_triangles` set-up); nil when
    /// nothing is drawn.
    static func prepare(verts: [MeshWarp.Vertex], tris: [SIMD3<Int32>]) -> Prepared? {
        if tris.isEmpty { return nil }
        if verts.contains(where: { !$0.dst.x.isFinite || !$0.dst.y.isFinite }) { return nil }
        let lim = Double(1 << 20)
        var (x0, y0, x1, y1) = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        for t in tris {
            for k in 0..<3 {
                let v = verts[Int(t[k])].dst
                x0 = min(x0, v.x); y0 = min(y0, v.y); x1 = max(x1, v.x); y1 = max(y1, v.y)
            }
        }
        let dst = PixelRect(x0: ResampleKit.i32(max(x0, -lim).rounded(.down)) - 1, y0: ResampleKit.i32(max(y0, -lim).rounded(.down)) - 1,
                            x1: ResampleKit.i32(min(x1, lim).rounded(.up)) + 1, y1: ResampleKit.i32(min(y1, lim).rounded(.up)) + 1)
        let tiles = TransformKit.tiles(dst)
        if tiles.isEmpty { return nil }
        var bins = [[Int32]](repeating: [], count: tiles.count)
        let ts = tileSize
        // Bin origin on the tile grid (the first tile is clipped to `dst`, so its x0/y0 may not be).
        let tx0 = ResampleKit.floorDiv(tiles.map(\.x0).min() ?? 0, ts) * ts
        let ty0 = ResampleKit.floorDiv(tiles.map(\.y0).min() ?? 0, ts) * ts
        let cols = Int((tiles.map { ($0.x0 - tx0) / ts }.max() ?? 0)) + 1
        let rows = Int((tiles.map { ($0.y0 - ty0) / ts }.max() ?? 0)) + 1
        var lookup = [Int](repeating: -1, count: cols * rows)
        for (k, t) in tiles.enumerated() { lookup[Int((t.y0 - ty0) / ts) * cols + Int((t.x0 - tx0) / ts)] = k }
        for (ti, tri) in tris.enumerated() {
            let p0 = verts[Int(tri[0])].dst, p1 = verts[Int(tri[1])].dst, p2 = verts[Int(tri[2])].dst
            let bx0 = ResampleKit.i32(min(p0.x, p1.x, p2.x).rounded(.down))
            let by0 = ResampleKit.i32(min(p0.y, p1.y, p2.y).rounded(.down))
            let bx1 = ResampleKit.i32(max(p0.x, p1.x, p2.x).rounded(.up))
            let by1 = ResampleKit.i32(max(p0.y, p1.y, p2.y).rounded(.up))
            let cx0 = ResampleKit.floorDiv(max(bx0, dst.x0) - tx0, ts), cy0 = ResampleKit.floorDiv(max(by0, dst.y0) - ty0, ts)
            let cx1 = ResampleKit.floorDiv(min(bx1, dst.x1 - 1) - tx0, ts), cy1 = ResampleKit.floorDiv(min(by1, dst.y1 - 1) - ty0, ts)
            var cy = max(cy0, 0)
            while cy <= cy1 {
                var cx = max(cx0, 0)
                while cx <= cx1 {
                    let g = Int(cy) * cols + Int(cx)
                    if g < lookup.count, lookup[g] >= 0 { bins[lookup[g]].append(Int32(ti)) }
                    cx += 1
                }
                cy += 1
            }
        }
        return Prepared(verts: verts, tris: tris, dst: dst, tiles: tiles, bins: bins)
    }

    /// Subsamples along one destination axis, from the source step `j` it makes: one where the
    /// warp keeps or enlarges the source, else about one per source pixel the output pixel spans.
    @inline(__always)
    static func count(_ j: SIMD2<Double>, _ interp: Interp) -> Int {
        interp == .nearest ? 1 : Int(min(max(hypot(j.x, j.y).rounded(), 1), maxSS))
    }

    /// Jacobian and subsample counts of every triangle.
    static func triInfo(_ p: Prepared, _ interp: Interp) -> [TriInfo] {
        var out = [TriInfo](repeating: TriInfo(j: .zero, nx: 1, ny: 1), count: p.tris.count)
        out.withUnsafeMutableBufferPointer { ob in
            let o = UnsafeSendable(ob)
            parallelChunks(p.tris.count, minChunk: 4096) { r in
                for k in r {
                    let tri = p.tris[k]
                    let (v0, v1, v2) = (p.verts[Int(tri[0])], p.verts[Int(tri[1])], p.verts[Int(tri[2])])
                    let (p0, p1, p2, s0, s1, s2) = (v0.dst, v1.dst, v2.dst, v0.src, v1.src, v2.src)
                    let det = (p1.x - p0.x) * (p2.y - p0.y) - (p2.x - p0.x) * (p1.y - p0.y)
                    if abs(det) < 1e-12 { continue }
                    let d1 = s1 - s0, d2 = s2 - s0
                    let (l1x, l1y, l2x, l2y) = ((p2.y - p0.y) / det, (p0.x - p2.x) / det, (p0.y - p1.y) / det, (p1.x - p0.x) / det)
                    // Capped, so a sliver triangle can't ask for an unbounded footprint.
                    func cap(_ j: SIMD2<Double>) -> SIMD2<Double> {
                        let l = hypot(j.x, j.y)
                        return l > maxSS ? SIMD2(j.x * maxSS / l, j.y * maxSS / l) : j
                    }
                    let jx = cap(SIMD2(l1x * d1.x + l2x * d2.x, l1x * d1.y + l2x * d2.y))
                    let jy = cap(SIMD2(l1y * d1.x + l2y * d2.x, l1y * d1.y + l2y * d2.y))
                    let nx = count(jx, interp), ny = count(jy, interp)
                    if nx * ny != 1 { o.value[k] = TriInfo(j: SIMD4(jx.x, jx.y, jy.x, jy.y), nx: nx, ny: ny) }
                }
            }
        }
        return out
    }

    /// Rasterises tile `t`'s triangles: the source position of each covered pixel (NaN when
    /// uncovered) and the triangle it came from (the last one in depth order).
    static func raster(_ p: Prepared, tile ti: Int, uv: inout [SIMD2<Double>], owner: inout [Int32]) {
        let t = p.tiles[ti]
        let w = t.width
        let count = t.area
        if uv.count != count { uv = [SIMD2<Double>](repeating: SIMD2(.nan, .nan), count: count) } else { for i in 0..<count { uv[i] = SIMD2(.nan, .nan) } }
        if owner.count != count { owner = [Int32](repeating: -1, count: count) } else { for i in 0..<count { owner[i] = -1 } }
        for k in p.bins[ti] {
            let tri = p.tris[Int(k)]
            let (v0, v1, v2) = (p.verts[Int(tri[0])], p.verts[Int(tri[1])], p.verts[Int(tri[2])])
            let (p0, p1, p2, s0, s1, s2) = (v0.dst, v1.dst, v2.dst, v0.src, v1.src, v2.src)
            let det = (p1.x - p0.x) * (p2.y - p0.y) - (p2.x - p0.x) * (p1.y - p0.y)
            if abs(det) < 1e-12 { continue }
            let bx0 = ResampleKit.i32(max((min(p0.x, p1.x, p2.x) - 0.5).rounded(.down), Double(t.x0)))
            let by0 = ResampleKit.i32(max((min(p0.y, p1.y, p2.y) - 0.5).rounded(.down), Double(t.y0)))
            let bx1 = ResampleKit.i32(min((max(p0.x, p1.x, p2.x) + 0.5).rounded(.up), Double(t.x1)))
            let by1 = ResampleKit.i32(min((max(p0.y, p1.y, p2.y) + 0.5).rounded(.up), Double(t.y1)))
            let eps = -1e-9
            var y = by0
            while y < by1 {
                let py = Double(y) + 0.5
                var x = bx0
                while x < bx1 {
                    let px = Double(x) + 0.5
                    let l1 = ((px - p0.x) * (p2.y - p0.y) - (p2.x - p0.x) * (py - p0.y)) / det
                    let l2 = ((p1.x - p0.x) * (py - p0.y) - (px - p0.x) * (p1.y - p0.y)) / det
                    let l0 = 1.0 - l1 - l2
                    if !(l0 < eps || l1 < eps || l2 < eps) {
                        let o = Int(y - t.y0) * w + Int(x - t.x0)
                        uv[o] = SIMD2(l0 * s0.x + l1 * s1.x + l2 * s2.x, l0 * s0.y + l1 * s1.y + l2 * s2.y)
                        owner[o] = k
                    }
                    x += 1
                }
                y += 1
            }
        }
    }

    /// Source footprint of the covered pixels, including the spread of their subsamples, grown by
    /// 3 px and clipped to `srcRect`; nil when nothing is covered.
    static func footprint(_ uv: [SIMD2<Double>], _ owner: [Int32], _ info: [TriInfo], srcRect: PixelRect) -> PixelRect? {
        var (fx0, fy0, fx1, fy1) = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        for (q, k) in zip(uv, owner) where !q.x.isNaN {
            let j = info[Int(k)].j
            let ex = 0.5 * (abs(j[0]) + abs(j[2])), ey = 0.5 * (abs(j[1]) + abs(j[3]))
            fx0 = min(fx0, q.x - ex); fy0 = min(fy0, q.y - ey)
            fx1 = max(fx1, q.x + ex); fy1 = max(fy1, q.y + ey)
        }
        if fx0 > fx1 { return nil }
        let foot = PixelRect(x0: ResampleKit.i32(fx0.rounded(.down)) - 3, y0: ResampleKit.i32(fy0.rounded(.down)) - 3,
                             x1: ResampleKit.i32(fx1.rounded(.up)) + 3, y1: ResampleKit.i32(fy1.rounded(.up)) + 3).intersect(srcRect)
        return foot.isEmpty ? nil : foot
    }

    @inline(__always)
    static func snap(_ t: Double) -> Double { abs(t - t.rounded()) < 1e-7 ? t.rounded() : t }

    /// Samples the covered pixels of one tile (photocraft's `point` and subsample loop); `px` is the
    /// premultiplied source over `foot`. Returns whether any pixel was drawn.
    static func sample(_ uv: [SIMD2<Double>], _ owner: [Int32], _ info: [TriInfo], interp: Interp, foot: PixelRect,
                       px: UnsafeBufferPointer<Float>, n: Int, into outp: UnsafeMutableBufferPointer<Float>, base: (Int) -> Int) -> Bool {
        let a = n - 1, fw = foot.width
        @inline(__always) func at(_ x: Int32, _ y: Int32, _ c: Int) -> Double {
            if x < foot.x0 || y < foot.y0 || x >= foot.x1 || y >= foot.y1 { return 0 }
            return Double(px[(Int(y - foot.y0) * fw + Int(x - foot.x0)) * n + c])
        }
        // One premultiplied sample at source position (u, v) (pixel centres at integers).
        func point(_ interp: Interp, _ u0: Double, _ v0: Double, _ acc: inout [Double]) {
            for c in 0..<n { acc[c] = 0 }
            switch interp {
            case .nearest:
                let ix = ResampleKit.i32((u0 + 0.5).rounded(.down)), iy = ResampleKit.i32((v0 + 0.5).rounded(.down))
                for c in 0..<n { acc[c] = at(ix, iy, c) }
            case .bilinear:
                let ix = ResampleKit.i32(u0.rounded(.down)), iy = ResampleKit.i32(v0.rounded(.down))
                let fx = u0 - Double(ix), fy = v0 - Double(iy)
                for (dy, wy) in [(Int32(0), 1 - fy), (1, fy)] {
                    for (dx, wx) in [(Int32(0), 1 - fx), (1, fx)] {
                        for c in 0..<n { acc[c] += at(ix + dx, iy + dy, c) * wx * wy }
                    }
                }
            case .bicubic:
                // Snap to the pixel grid when within float noise, so identity is exact.
                let u = snap(u0), v = snap(v0)
                let ix = ResampleKit.i32(u.rounded(.down)), iy = ResampleKit.i32(v.rounded(.down))
                let cx = TransformKit.catmullRom(u - Double(ix)), cy = TransformKit.catmullRom(v - Double(iy))
                let wx = [cx.0, cx.1, cx.2, cx.3], wy = [cy.0, cy.1, cy.2, cy.3]
                for j in 0..<4 {
                    for i in 0..<4 {
                        let k = wx[i] * wy[j]
                        if k == 0 { continue }
                        for c in 0..<n { acc[c] += at(ix - 1 + Int32(i), iy - 1 + Int32(j), c) * k }
                    }
                }
            }
        }
        var any = false
        var acc = [Double](repeating: 0, count: n), one = [Double](repeating: 0, count: n)
        for (o, (q, k)) in zip(uv, owner).enumerated() where !q.x.isNaN {
            let ti = info[Int(k)]
            if ti.nx * ti.ny == 1 {
                point(interp, q.x - 0.5, q.y - 0.5, &acc)
            } else {
                for c in 0..<n { acc[c] = 0 }
                let j = ti.j
                for sy in 0..<ti.ny {
                    let t = (Double(sy) + 0.5) / Double(ti.ny) - 0.5
                    for sx in 0..<ti.nx {
                        let s = (Double(sx) + 0.5) / Double(ti.nx) - 0.5
                        point(.bilinear, q.x + s * j[0] + t * j[2] - 0.5, q.y + s * j[1] + t * j[3] - 0.5, &one)
                        for c in 0..<n { acc[c] += one[c] }
                    }
                }
                let kk = 1.0 / Double(ti.nx * ti.ny)
                for c in 0..<n { acc[c] *= kk }
            }
            let al = min(max(acc[a], 0), 1)
            // Float noise (a vertex a hair off the pixel grid) must not leave invisible colour
            // behind in transparent pixels.
            if al <= 1e-6 { continue }
            any = true
            let b = base(o)
            for c in 0..<a { outp[b + c] = Float(min(max(acc[c] / al, 0), 1)) }
            outp[b + a] = Float(al)
        }
        return any
    }

    /// The CPU warp of a dense image with alpha into a dense result over `p.dst`.
    static func warpCPU(_ src: FloatImage, _ p: Prepared, srcRect: PixelRect, interp: Interp) -> FloatImage {
        let n = src.channels
        var res = FloatImage(rect: p.dst, channels: n)
        let info = triInfo(p, interp)
        let ow = p.dst.width
        res.data.withUnsafeMutableBufferPointer { rb in
            let r = UnsafeSendable(rb)
            parallelFor(p.tiles.count) { ti in
                if p.bins[ti].isEmpty { return }
                let t = p.tiles[ti]
                var uv: [SIMD2<Double>] = [], owner: [Int32] = []
                raster(p, tile: ti, uv: &uv, owner: &owner)
                guard let foot = footprint(uv, owner, info, srcRect: srcRect), !foot.intersect(src.rect).isEmpty else { return }
                let px = TransformKit.premulWindow(src, foot)
                let tw = t.width
                px.withUnsafeBufferPointer { pp in
                    _ = sample(uv, owner, info, interp: interp, foot: foot, px: pp, n: n, into: r.value) { o in
                        (Int(t.y0 - p.dst.y0 + Int32(o / tw)) * ow + Int(t.x0 - p.dst.x0) + o % tw) * n
                    }
                }
            }
        }
        return res
    }

    /// `warpTriangles` on a surface (photocraft `warp_triangles`).
    static func warpTrianglesSurface(_ src: Surface, srcRect: PixelRect, verts: [MeshWarp.Vertex], tris: [SIMD3<Int32>], interp: Interp,
                                     backend: Backend) -> Surface {
        let fmt = src.format.with(alpha: true)
        var out = Surface(format: fmt)
        if srcRect.isEmpty { return out }
        guard let p = prepare(verts: verts, tris: tris) else { return out }
        let addAlpha = !src.format.alpha
        // The dense GPU image reads transparency outside the content: only for surfaces whose
        // default pixel is transparent (with alpha, so the conversion doesn't make it opaque).
        if backend != .cpu, AlgoGPU.isAvailable, src.format.alpha, src.defaultPixelValue.allSatisfy({ $0 == 0 }) {
            let content = ResampleKit.contentBounds(src).intersect(srcRect)
            let m = FilterEngine.maxGPUSize
            if content.isEmpty { return out }
            if content.width <= m && content.height <= m && content.area <= 1 << 26 && p.dst.width <= m && p.dst.height <= m && p.dst.area <= 1 << 26 {
                let img = FloatImage(rect: content, channels: fmt.channels, data: TransformKit.readWithAlpha(src, content, addAlpha: addAlpha))
                let ctx = FilterContext(bounds: p.dst, format: fmt)
                if let r = try? FilterEngine.apply(MeshFilter(prepared: p, srcRect: srcRect, interp: interp), to: img, output: p.dst, context: ctx, on: .gpu) {
                    ResampleKit.write(&out, r.rect, r.data)
                    ResampleKit.prune(&out)
                    return out
                }
            }
        }
        let n = fmt.channels
        let info = triInfo(p, interp)
        var done = [(PixelRect, [Float])?](repeating: nil, count: p.tiles.count)
        done.withUnsafeMutableBufferPointer { db in
            let d = UnsafeSendable(db)
            parallelFor(p.tiles.count) { ti in
                if p.bins[ti].isEmpty { return }
                let t = p.tiles[ti]
                var uv: [SIMD2<Double>] = [], owner: [Int32] = []
                raster(p, tile: ti, uv: &uv, owner: &owner)
                guard let foot = footprint(uv, owner, info, srcRect: srcRect), foot.tiles.contains(where: { src.tile($0) != nil }) else { return }
                var px = TransformKit.readWithAlpha(src, foot, addAlpha: addAlpha)
                premultiply(&px, n, true)
                var outp = [Float](repeating: 0, count: t.area * n)
                let any = px.withUnsafeBufferPointer { pp in
                    outp.withUnsafeMutableBufferPointer { o in
                        sample(uv, owner, info, interp: interp, foot: foot, px: pp, n: n, into: o) { $0 * n }
                    }
                }
                if any { d.value[ti] = (t, outp) }
            }
        }
        for case let (r, v)? in done { ResampleKit.write(&out, r, v) }
        ResampleKit.prune(&out)
        return out
    }

    /// The dense-image driver: CPU reference or the Metal sampling.
    static func run(_ img: FloatImage, _ p: Prepared, srcRect: PixelRect, interp: Interp, ctx: FilterContext, backend: Backend) throws -> FloatImage {
        let fits = max(img.width, img.height, p.dst.width, p.dst.height) <= FilterEngine.maxGPUSize && p.dst.area <= 1 << 26
        let useGPU: Bool
        switch backend {
        case .cpu: useGPU = false
        case .gpu:
            guard fits else { throw FilterError.gpuUnsupported("mesh warp larger than \(FilterEngine.maxGPUSize) px") }
            useGPU = true
        case .auto: useGPU = fits && AlgoGPU.isAvailable
        }
        var c = ctx
        c.bounds = p.dst
        return try FilterEngine.apply(MeshFilter(prepared: p, srcRect: srcRect, interp: interp), to: img, output: p.dst, context: c,
                                      on: useGPU ? .gpu : .cpu)
    }
}

// MARK: - Metal

extension MeshKit {
    /// MSL `pca_rs_mesh_px`: the sample base of one destination pixel (`owner` < 0: uncovered).
    struct GPUPixel: BitwiseCopyable {
        var bx: Int32
        var by: Int32
        var fx: Float
        var fy: Float
        var owner: Int32
    }

    /// MSL `pca_rs_mesh_tri`.
    struct GPUTri: BitwiseCopyable {
        var j: SIMD4<Float>
        var nx: Int32
        var ny: Int32
        var pad0: Int32 = 0
        var pad1: Int32 = 0
    }

    /// MSL `pca_rs_mesh_params`.
    struct MeshParams: BitwiseCopyable {
        var rectLo: SIMD2<Int32>
        var rectHi: SIMD2<Int32>
        var interp: Int32
        var pad0: Int32 = 0
        var pad1: Int32 = 0
        var pad2: Int32 = 0
    }

    /// The per-pixel table over `p.dst`: the rasterisation (exact, CPU) reduced to what the
    /// sampler needs — the integer cell and fraction of a point sample (computed in f64, so the
    /// nearest pixel and the bicubic snap are photocraft's), or the base of the subsample grid.
    static func gpuTable(_ p: Prepared, _ info: [TriInfo], interp: Interp, into table: UnsafeMutablePointer<GPUPixel>) {
        let ow = p.dst.width
        let tt = UnsafeSendable(table)
        parallelFor(p.tiles.count) { ti in
            let t = p.tiles[ti]
            let tw = t.width
            @inline(__always) func index(_ o: Int) -> Int { Int(t.y0 - p.dst.y0 + Int32(o / tw)) * ow + Int(t.x0 - p.dst.x0) + o % tw }
            for o in 0..<t.area { tt.value[index(o)] = GPUPixel(bx: 0, by: 0, fx: 0, fy: 0, owner: -1) }
            if p.bins[ti].isEmpty { return }
            var uv: [SIMD2<Double>] = [], owner: [Int32] = []
            raster(p, tile: ti, uv: &uv, owner: &owner)
            for (o, (q, k)) in zip(uv, owner).enumerated() where !q.x.isNaN {
                let point = info[Int(k)].nx * info[Int(k)].ny == 1
                var u = q.x - 0.5, v = q.y - 0.5
                if point && interp == .nearest { u += 0.5; v += 0.5 }
                if point && interp == .bicubic { u = snap(u); v = snap(v) }
                let bu = u.rounded(.down), bv = v.rounded(.down)
                tt.value[index(o)] = GPUPixel(bx: ResampleKit.i32(bu), by: ResampleKit.i32(bv), fx: Float(u - bu), fy: Float(v - bv), owner: k)
            }
        }
    }

    /// The mesh warp as a filter over `prepared.dst` (the source has alpha).
    struct MeshFilter: Filter {
        var prepared: Prepared
        var srcRect: PixelRect
        var interp: Interp
        var label: String { "Warp" }
        func halo(bounds: PixelRect) -> Halo { .bounds }

        func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
            precondition(ctx.alpha && out == prepared.dst)
            return warpCPU(src, prepared, srcRect: srcRect, interp: interp)
        }

        func encodeGPU(_ pass: GPUPass) throws {
            let info = triInfo(prepared, interp)
            // The per-pixel table is written straight into a shared buffer (it is large: 20 bytes
            // per destination pixel).
            let len = MemoryLayout<GPUPixel>.stride * max(prepared.dst.area, 1)
            guard let pb = pass.gpu.device.makeBuffer(length: len, options: .storageModeShared) else {
                throw FilterError.gpuUnavailable("makeBuffer \(len)")
            }
            gpuTable(prepared, info, interp: interp, into: pb.contents().bindMemory(to: GPUPixel.self, capacity: max(prepared.dst.area, 1)))
            let tris = info.map { GPUTri(j: SIMD4<Float>($0.j), nx: Int32($0.nx), ny: Int32($0.ny)) }
            let tb = try pass.buffer(tris)
            let p = MeshParams(rectLo: SIMD2(srcRect.x0, srcRect.y0), rectHi: SIMD2(srcRect.x1, srcRect.y1), interp: interp.code)
            try pass.dispatchOut("pca_rs_mesh", params: p, buffers: [pb, tb])
        }
    }
}
