// Port of photocraft-algo (crates/algo/src/vanishing.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Vanishing Point: perspective planes, pasting onto a plane and cloning in perspective.
// A plane is a quad aligned with a flat surface in the photo. Its two vanishing points give the
// camera's focal length for a centred principal point, f² = −(v₁ − c)·(v₂ − c) (Hartley &
// Zisserman, Multiple View Geometry, 2nd ed., §8.8), which lifts the quad to 3-D: the plane's
// metric aspect (pasted images keep their proportions) and perpendicular planes torn off an edge.
// Pasting warps through the composed homography (`Transform.warp`, GPU-capable), clipped to the
// plane; clone stamping copies, per destination pixel, the pixel at the same metric offset from
// the source point (CPU, per dab).

import Foundation
import PCFoundation

/// A perspective plane: corners in image px, clockwise from the plane's top-left (photocraft
/// `VpPlane`).
public struct VpPlane: Hashable, Sendable, Codable {
    public var corners: [SIMD2<Double>]
    public init(corners: [SIMD2<Double>]) {
        precondition(corners.count == 4, "a plane has four corners")
        self.corners = corners
    }

    /// Unit square (u, v) → image.
    public func homography() -> Homography? { Homography.rectToQuad([0, 0, 1, 1], corners) }

    /// Focal length (px) implied by the plane's two vanishing points, if both are finite and
    /// consistent with a camera centred at `c`.
    public func focal(_ c: SIMD2<Double>) -> Double? {
        let q = corners
        let v1 = VpKit.meet(q[0], q[1], q[3], q[2]), v2 = VpKit.meet(q[0], q[3], q[1], q[2])
        if abs(v1.z) < 1e-9 || abs(v2.z) < 1e-9 { return nil }
        let a = SIMD2(v1.x / v1.z - c.x, v1.y / v1.z - c.y), b = SIMD2(v2.x / v2.z - c.x, v2.y / v2.z - c.y)
        let f2 = -(a.x * b.x + a.y * b.y)
        return f2 > 1 ? f2.squareRoot() : nil
    }

    /// Lifts the plane to 3-D with focal `f` (camera at the origin looking along +z).
    public func lift(_ f: Double, _ c: SIMD2<Double>) -> VanishingPoint.Lifted {
        func ray(_ p: SIMD2<Double>) -> SIMD3<Double> { SIMD3((p.x - c.x) / f, (p.y - c.y) / f, 1) }
        let q = corners
        // Vanishing directions (or the edge directions when they're parallel in the image).
        func dir(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ cc: SIMD2<Double>, _ d: SIMD2<Double>) -> SIMD3<Double> {
            let v = VpKit.meet(a, b, cc, d)
            if abs(v.z) < 1e-9 * fmax(abs(v.x) + abs(v.y), 1) { return VpKit.norm(SIMD3(v.x, v.y, 0)) }
            return VpKit.norm(ray(SIMD2(v.x / v.z, v.y / v.z)))
        }
        let d1 = dir(q[0], q[1], q[3], q[2]), d2 = dir(q[0], q[3], q[1], q[2])
        var n = VpKit.norm(VpKit.cross(d1, d2))
        if n.z < 0 { n = VpKit.mul(n, -1) }
        let pts = q.map { p -> SIMD3<Double> in
            let r = ray(p)
            let lam = 1 / fmax(abs(VpKit.dot(n, r)), 1e-9)
            return VpKit.mul(r, lam)
        }
        return VanishingPoint.Lifted(focal: f, center: c, pts: pts)
    }

    /// Turn of each corner (sin of the angle between consecutive edges, positive clockwise on
    /// screen); nil when an edge is shorter than a pixel or a corner is not finite.
    func turns() -> [Double]? {
        let q = corners
        if q.contains(where: { !$0.x.isFinite || !$0.y.isFinite || abs($0.x) > 1e9 || abs($0.y) > 1e9 }) { return nil }
        func e(_ i: Int) -> SIMD2<Double> { SIMD2(q[(i + 1) % 4].x - q[i].x, q[(i + 1) % 4].y - q[i].y) }
        var out = [Double](repeating: 0, count: 4)
        for i in 0..<4 {
            let a = e(i), b = e((i + 1) % 4)
            let la = hypot(a.x, a.y), lb = hypot(b.x, b.y)
            if la < 1 || lb < 1 { return nil }
            out[i] = (a.x * b.y - a.y * b.x) / (la * lb)
        }
        return out
    }

    /// How usable the plane is (Photoshop's blue / yellow / red grid).
    public func check(_ center: SIMD2<Double>) -> VanishingPoint.PlaneCheck {
        guard let t = turns() else { return .invalid }
        let sameSign = t.allSatisfy { $0 > 0 } || t.allSatisfy { $0 < 0 }
        let mn = t.reduce(Double.greatestFiniteMagnitude) { fmin($0, abs($1)) }
        if !sameSign || mn < sin(1 * (Double.pi / 180)) || homography() == nil { return .invalid }
        if mn < sin(10 * (Double.pi / 180)) { return .questionable }
        // Both vanishing points finite but no real focal length fits them.
        let q = corners
        let v1 = VpKit.meet(q[0], q[1], q[3], q[2]), v2 = VpKit.meet(q[0], q[3], q[1], q[2])
        func finite(_ v: SIMD3<Double>) -> Bool { abs(v.z) > 1e-9 * fmax(abs(v.x) + abs(v.y), 1) }
        if finite(v1) && finite(v2) && focal(center) == nil { return .questionable }
        return .valid
    }

    /// The same quad with its corners clockwise on screen from the top-left one, however they were
    /// clicked.
    public func normalized() -> VpPlane {
        var q = corners
        if let t = turns(), t.reduce(0, +) < 0 { q = [q[0], q[3], q[2], q[1]] }
        var first = 0
        for a in 1..<4 where q[a].x + q[a].y < q[first].x + q[first].y { first = a }
        return VpPlane(corners: [q[first], q[(first + 1) % 4], q[(first + 2) % 4], q[(first + 3) % 4]])
    }
}

/// Vanishing Point types and operations (photocraft `vanishing.rs`).
public enum VanishingPoint {
    /// Plane edges for tearing off a perpendicular plane (photocraft `Edge`).
    public enum Edge: String, Codable, Sendable, Hashable, CaseIterable { case top, right, bottom, left }

    /// Plane validity: Photoshop draws a valid plane's grid blue, a doubtful one yellow and an
    /// invalid one red (photocraft `PlaneCheck`).
    public enum PlaneCheck: String, Codable, Sendable, Hashable, CaseIterable { case valid, questionable, invalid }

    /// The camera and a plane lifted to 3-D (photocraft `Lifted`).
    public struct Lifted: Hashable, Sendable {
        public var focal: Double
        public var center: SIMD2<Double>
        /// 3-D corners (camera coordinates, plane at unit distance along its normal).
        public var pts: [SIMD3<Double>]

        public func project(_ x: SIMD3<Double>) -> SIMD2<Double>? {
            x.z > 1e-9 ? SIMD2(center.x + focal * x.x / x.z, center.y + focal * x.y / x.z) : nil
        }

        /// Metric side lengths (u along the top edge, v along the left edge).
        public func lengths() -> (Double, Double) {
            func l(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { let d = VpKit.sub(a, b); return VpKit.dot(d, d).squareRoot() }
            return ((l(pts[0], pts[1]) + l(pts[3], pts[2])) / 2, (l(pts[0], pts[3]) + l(pts[1], pts[2])) / 2)
        }
    }

    /// A scene: planes plus the shared focal length (photocraft `Scene`).
    public struct Scene: Hashable, Sendable {
        public var planes: [VpPlane]
        public var focal: Double
        public var center: SIMD2<Double>

        /// Focal length from the first plane (or `fallback` px when it is fronto-parallel).
        public init(first: VpPlane, center: SIMD2<Double>, focal: Double? = nil, fallback: Double) {
            let f = focal.flatMap { $0 > 1 ? $0 : nil } ?? first.focal(center) ?? fallback
            planes = [first]; self.focal = f; self.center = center
        }

        public func lifted(_ i: Int) -> Lifted { planes[i].lift(focal, center) }

        /// Tears a plane off edge `edge` of plane `from`, turned by `angle` degrees about that edge
        /// (90 = perpendicular), extending `depth` times the parent's adjacent side. Returns its
        /// index.
        public mutating func tearOff(from: Int, edge: Edge, angle: Double, depth: Double) -> Int? {
            let lf = lifted(from)
            let p = lf.pts
            // Edge endpoints (a → b, clockwise) and the parent's inward direction.
            let (ia, ib, ic): (Int, Int, Int)
            switch edge {
            case .top: (ia, ib, ic) = (0, 1, 3)
            case .right: (ia, ib, ic) = (1, 2, 0)
            case .bottom: (ia, ib, ic) = (2, 3, 1)
            case .left: (ia, ib, ic) = (3, 0, 2)
            }
            let a = p[ia], b = p[ib]
            let axis = VpKit.norm(VpKit.sub(b, a))
            let inward = VpKit.sub(p[ic], p[ia])
            let len = VpKit.dot(inward, inward).squareRoot() * fmax(depth, 0.05)
            // The new plane continues outward, turned about the edge by 180° − angle; of the two
            // directions pick the one facing the camera with the parent in front (a room corner).
            let out = VpKit.mul(VpKit.norm(inward), -1)
            let th = (180 - angle) * (Double.pi / 180)
            var best: (Double, [SIMD2<Double>])? = nil
            for sgn in [1.0, -1.0] {
                let s = sin(sgn * th), c = cos(sgn * th)
                let rot = VpKit.add(VpKit.add(VpKit.mul(out, c), VpKit.mul(VpKit.cross(axis, out), s)), VpKit.mul(axis, VpKit.dot(axis, out) * (1 - c)))
                let a2 = VpKit.add(a, VpKit.mul(rot, len)), b2 = VpKit.add(b, VpKit.mul(rot, len))
                guard let pa = lf.project(a), let pb = lf.project(b), let pa2 = lf.project(a2), let pb2 = lf.project(b2) else { continue }
                var n2 = VpKit.norm(VpKit.cross(VpKit.sub(b, a), VpKit.sub(a2, a)))
                if VpKit.dot(n2, a) > 0 { n2 = VpKit.mul(n2, -1) }
                let score = VpKit.dot(n2, inward)
                if best.map({ score > $0.0 }) ?? true { best = (score, [pa, pb, pa2, pb2]) }
            }
            guard let (_, q) = best else { return nil }
            let (pa, pb, pa2, pb2) = (q[0], q[1], q[2], q[3])
            // Keep corners clockwise from the new plane's top-left (shared edge first or last).
            let corners: [SIMD2<Double>]
            switch edge {
            case .top: corners = [pa2, pb2, pb, pa]
            case .right: corners = [pa, pa2, pb2, pb]
            case .bottom: corners = [pb, pa, pa2, pb2]
            case .left: corners = [pb2, pb, pa, pa2]
            }
            planes.append(VpPlane(corners: corners))
            return planes.count - 1
        }

        /// Plane-metric frame of plane `i`: (unit square → image homography, metric width, height).
        public func frame(_ i: Int) -> (Homography, Double, Double)? {
            guard let h = planes[i].homography() else { return nil }
            let (lu, lv) = lifted(i).lengths()
            return (h, lu, lv)
        }

        /// The plane whose quad contains image point `p` (the last one drawn wins).
        public func plane(at p: SIMD2<Double>) -> Int? {
            planes.indices.reversed().first { i in
                guard let inv = planes[i].homography()?.inverse() else { return false }
                let (u, v) = inv.apply(p.x, p.y)
                return u >= 0 && u <= 1 && v >= 0 && v <= 1
            }
        }
    }

    /// Pastes `src` (content in `srcRect`) onto plane `i` with its top-left at plane coordinates
    /// `at` (0…1) and its width `width` (fraction of the plane's width), aspect preserved in the
    /// plane's metric: the warped image clipped to the plane, transparent elsewhere (photocraft
    /// `paste`). nil when the plane or the source is degenerate.
    public static func paste(_ scene: Scene, plane i: Int, _ src: Surface, srcRect: PixelRect, at: SIMD2<Double>, width: Double,
                             on backend: Backend = .auto) -> Surface? {
        guard let (h, full) = VpKit.pasteMap(scene, i, srcRect, at, width) else { return nil }
        var out = Transform.warpSurface(src, srcRect: srcRect, h: full, interp: .bicubic, on: backend)
        // Clip to the plane.
        let b = ResampleKit.contentBounds(out)
        if b.isEmpty { return out }
        let mask = VpKit.quadMask(h, b)
        let n = out.channels
        var data = out.readRegion(b)
        for (k, m) in mask.enumerated() { data[k * n + n - 1] *= m }
        ResampleKit.write(&out, b, data)
        ResampleKit.prune(&out)
        return out
    }

    /// `paste` on a dense image (0 outside it): the warped rectangle clipped to the plane, alpha
    /// appended when `context` has none.
    public static func paste(_ scene: Scene, plane i: Int, _ img: FloatImage, srcRect: PixelRect? = nil, at: SIMD2<Double>, width: Double,
                             context: FilterContext? = nil, on backend: Backend = .auto) throws -> FloatImage? {
        let sr = srcRect ?? img.rect
        guard let (h, full) = VpKit.pasteMap(scene, i, sr, at, width) else { return nil }
        var out = try Transform.warp(img, srcRect: sr, h: full, interp: .bicubic, context: context, on: backend)
        if out.rect.isEmpty { return out }
        let mask = VpKit.quadMask(h, out.rect)
        let n = out.channels
        for (k, m) in mask.enumerated() { out.data[k * n + n - 1] *= m }
        return out
    }

    /// Perspective clone stamp: one stroke of dabs at image points `points` on the destination
    /// plane, copying from `source` (image px) with the offset fixed in plane-metric units at the
    /// first dab. `size` is the brush diameter in px at the first dab; `hardness` 0…1. Returns the
    /// number of dabs that changed pixels (photocraft `clone_stroke`). CPU (a dab is a brush-sized
    /// region).
    @discardableResult
    public static func cloneStroke(_ scene: Scene, _ surf: inout Surface, source: SIMD2<Double>, points: [SIMD2<Double>], size: Double,
                                   hardness: Double, opacity: Float) -> Int {
        guard let first = points.first else { return 0 }
        guard let ps = scene.plane(at: source), let pd = scene.plane(at: first) else { return 0 }
        guard let (hs, lus, lvs) = scene.frame(ps), let (hd, lud, lvd) = scene.frame(pd) else { return 0 }
        guard let hsInv = hs.inverse(), let hdInv = hd.inverse() else { return 0 }
        func metric(_ inv: Homography, _ lu: Double, _ lv: Double, _ p: SIMD2<Double>) -> SIMD2<Double> {
            let (u, v) = inv.apply(p.x, p.y)
            return SIMD2(u * lu, v * lv)
        }
        let ms = metric(hsInv, lus, lvs, source)
        let md0 = metric(hdInv, lud, lvd, first)
        let offset = SIMD2(ms.x - md0.x, ms.y - md0.y)
        // Brush radius in metric units (from the image size at the first dab).
        let probe = metric(hdInv, lud, lvd, SIMD2(first.x + size / 2, first.y))
        let rM = fmax(hypot(probe.x - md0.x, probe.y - md0.y), 1e-9)
        let srcCopy = surf
        let n = surf.channels
        var dabs = 0
        for p in points {
            let mc = metric(hdInv, lud, lvd, p)
            // Image-space footprint: map a metric circle's bounding points.
            var bb = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
            for k in 0..<16 {
                let a = Double(k) / 16 * (2 * Double.pi)
                let (x, y) = hd.apply((mc.x + rM * cos(a)) / lud, (mc.y + rM * sin(a)) / lvd)
                bb = (fmin(bb.0, x), fmin(bb.1, y), fmax(bb.2, x), fmax(bb.3, y))
            }
            let area = PixelRect(x0: ResampleKit.i32(bb.0.rounded(.down)), y0: ResampleKit.i32(bb.1.rounded(.down)),
                                 x1: VpKit.satAdd(ResampleKit.i32(bb.2.rounded(.up)), 1), y1: VpKit.satAdd(ResampleKit.i32(bb.3.rounded(.up)), 1))
            if area.isEmpty || area.width > 4096 || area.height > 4096 { continue }
            var data = surf.readRegion(area)
            let w = area.width
            var changed = false
            for i in 0..<area.area {
                let x = Double(area.x0) + Double(i % w) + 0.5, y = Double(area.y0) + Double(i / w) + 0.5
                let m = metric(hdInv, lud, lvd, SIMD2(x, y))
                let d = hypot(m.x - mc.x, m.y - mc.y) / rM
                if d >= 1 { continue }
                let hard = GeometryKit.clampR(hardness, 0, 0.99)
                let fall = d <= hard ? 1 : 1 - (d - hard) / (1 - hard)
                let k = Float(fall * fall * (3 - 2 * fall)) * opacity
                // Source pixel at the same metric offset.
                let sm = SIMD2(m.x + offset.x, m.y + offset.y)
                let (sx, sy) = hs.apply(sm.x / lus, sm.y / lvs)
                let s = VpKit.sample(srcCopy, sx - 0.5, sy - 0.5, n)
                for c in 0..<n { data[i * n + c] += (s[c] - data[i * n + c]) * k }
                changed = true
            }
            if changed {
                surf.writeRegion(area, data)
                dabs += 1
            }
        }
        return dabs
    }
}

enum VpKit {
    @inline(__always) static func sub(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> { SIMD3(a.x - b.x, a.y - b.y, a.z - b.z) }
    @inline(__always) static func add(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> { SIMD3(a.x + b.x, a.y + b.y, a.z + b.z) }
    @inline(__always) static func mul(_ a: SIMD3<Double>, _ k: Double) -> SIMD3<Double> { SIMD3(a.x * k, a.y * k, a.z * k) }
    @inline(__always) static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    @inline(__always) static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
    static func norm(_ a: SIMD3<Double>) -> SIMD3<Double> { mul(a, 1 / fmax(dot(a, a).squareRoot(), 1e-300)) }

    /// Intersection of lines (a, b) and (c, d) in homogeneous coordinates.
    static func meet(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> SIMD3<Double> {
        let l1 = cross(SIMD3(a.x, a.y, 1), SIMD3(b.x, b.y, 1)), l2 = cross(SIMD3(c.x, c.y, 1), SIMD3(d.x, d.y, 1))
        return cross(l1, l2)
    }

    static func satAdd(_ a: Int32, _ b: Int32) -> Int32 { let (r, o) = a.addingReportingOverflow(b); return o ? .max : r }

    /// The plane's unit-square homography and the composed source → image map of a paste.
    static func pasteMap(_ scene: VanishingPoint.Scene, _ i: Int, _ srcRect: PixelRect, _ at: SIMD2<Double>, _ width: Double) -> (Homography, Homography)? {
        guard let (h, lu, lv) = scene.frame(i) else { return nil }
        let sw = Double(srcRect.width), sh = Double(srcRect.height)
        if sw <= 0 || sh <= 0 { return nil }
        // Source px → plane (u, v): u spans `width`, v keeps the metric aspect.
        let su = width / sw
        let sv = width * lu / lv / sw
        let toPlane = Homography([su, 0, at.x - Double(srcRect.x0) * su, 0, sv, at.y - Double(srcRect.y0) * sv, 0, 0, 1])
        return (h, h.mul(toPlane))
    }

    /// Coverage mask (0/1) of a plane quad over `area`.
    static func quadMask(_ h: Homography, _ area: PixelRect) -> [Float] {
        guard let inv = h.inverse() else { return [Float](repeating: 0, count: area.area) }
        let w = area.width
        return (0..<area.area).map { i in
            let (u, v) = inv.apply(Double(area.x0) + Double(i % w) + 0.5, Double(area.y0) + Double(i / w) + 0.5)
            return u >= 0 && u <= 1 && v >= 0 && v <= 1 ? 1 : 0
        }
    }

    /// Bilinear sample of a surface at `(x, y)` (pixel indices; the default pixel outside).
    static func sample(_ s: Surface, _ x: Double, _ y: Double, _ n: Int) -> [Float] {
        let x0 = ResampleKit.i32(x.rounded(.down)), y0 = ResampleKit.i32(y.rounded(.down))
        let tx = Float(x - Double(x0)), ty = Float(y - Double(y0))
        let r = s.readRegion(PixelRect(x0: x0, y0: y0, x1: x0 &+ 2, y1: y0 &+ 2))
        return (0..<n).map { c in (r[c] * (1 - tx) + r[n + c] * tx) * (1 - ty) + (r[2 * n + c] * (1 - tx) + r[3 * n + c] * tx) * ty }
    }
}
