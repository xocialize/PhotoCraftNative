// Port of photocraft-algo (crates/algo/src/panorama.rs; `warpPlaced`/`planeMatrix` from crates/engine/src/photo_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Panorama stitching for File › Automate › Photomerge and Edit › Auto-Align / Auto-Blend Layers,
// after M. Brown, D. G. Lowe, "Automatic Panoramic Image Stitching using Invariant Features", IJCV
// 2007: features (Harris + steered BRIEF) → pair matching with RANSAC and Brown–Lowe verification
// → focal length from the pairwise homographies (Shum & Szeliski 2000) → projection (plane,
// cylinder, sphere) + motion per layout → maximum spanning tree + Levenberg–Marquardt bundle
// adjustment (optionally one radial distortion coefficient and the focal length) → gain +
// vignetting compensation (Goldman 2010) → seams (dynamic programming through each overlap) →
// multi-band blending (Burt & Adelson 1983, holes filled by push-pull).
//
// Deterministic. Registration works on luminance at a reduced scale; `Placement.scaled` maps the
// result back. The multi-band blend has a Metal path (`PanoramaGPU.swift`); the rest is
// sequential orchestration and small solves, on the CPU. Warping an image into the panorama
// (`warpPlaced`) uses `Transform` for planar placements and `MeshWarp` otherwise.

import Foundation
import PCFoundation

/// Photomerge / Auto-Align / Auto-Blend registration and blending (photocraft `panorama`).
public enum Panorama {
    /// Photomerge layouts.
    public enum Layout: String, Codable, Sendable, Hashable, CaseIterable {
        case auto, perspective, cylindrical, spherical, collage, reposition

        /// photocraft `Layout::parse`.
        public init?(parsing s: String) { self.init(rawValue: s) }
        public var name: String { rawValue }

        var projection: Projection {
            switch self { case .cylindrical: .cylinder; case .spherical: .sphere; default: .plane }
        }

        var motion: Motion {
            switch self {
            case .auto, .perspective: .homography
            case .cylindrical, .spherical: .euclidean
            case .collage: .similarity
            case .reposition: .translation
            }
        }
    }

    /// Surface an image is projected onto before its 2-D motion.
    public enum Projection: String, Codable, Sendable, Hashable, CaseIterable {
        case plane, cylinder, sphere
    }

    /// 2-D motion models in projected space.
    public enum Motion: String, Codable, Sendable, Hashable, CaseIterable {
        case translation
        /// Rotation + translation.
        case euclidean
        /// Rotation, uniform scale, translation.
        case similarity
        case homography

        var minPoints: Int {
            switch self { case .translation: 1; case .euclidean, .similarity: 2; case .homography: 4 }
        }

        var nParams: Int {
            switch self { case .translation: 2; case .euclidean: 3; case .similarity: 4; case .homography: 8 }
        }

        func toParams(_ h: Homography) -> [Double] {
            let m = h.m.map { $0 / h.m[8] }
            switch self {
            case .translation: return [m[2], m[5]]
            case .euclidean: return [atan2(m[3], m[0]), m[2], m[5]]
            case .similarity: return [m[0], m[3], m[2], m[5]]
            case .homography: return Array(m[0..<8])
            }
        }

        func toHomography(_ p: ArraySlice<Double>) -> Homography {
            let b = p.startIndex
            switch self {
            case .translation: return Homography([1, 0, p[b], 0, 1, p[b + 1], 0, 0, 1])
            case .euclidean:
                let s = sin(p[b]), c = cos(p[b])
                return Homography([c, -s, p[b + 1], s, c, p[b + 2], 0, 0, 1])
            case .similarity: return Homography([p[b], -p[b + 1], p[b + 2], p[b + 1], p[b], p[b + 3], 0, 0, 1])
            case .homography: return Homography([p[b], p[b + 1], p[b + 2], p[b + 3], p[b + 4], p[b + 5], p[b + 6], p[b + 7], 1])
            }
        }
    }

    // MARK: - Motion fitting

    /// Least-squares fit of `motion` mapping `src[i]` → `dst[i]` (photocraft `fit_motion`).
    public static func fitMotion(_ motion: Motion, src: [SIMD2<Double>], dst: [SIMD2<Double>]) -> Homography? {
        switch motion {
        case .translation: return Features.fit(.translation, src: src, dst: dst)
        case .similarity: return Features.fit(.similarity, src: src, dst: dst)
        case .homography: return Features.fit(.homography, src: src, dst: dst)
        case .euclidean:
            let n = src.count
            if n < 2 { return nil }
            let nf = Double(n)
            var cs = SIMD2<Double>(0, 0), cd = SIMD2<Double>(0, 0)
            for p in src { cs = SIMD2(cs.x + p.x / nf, cs.y + p.y / nf) }
            for p in dst { cd = SIMD2(cd.x + p.x / nf, cd.y + p.y / nf) }
            var sxx = 0.0, sxy = 0.0
            for (s, d) in zip(src, dst) {
                let a = SIMD2(s.x - cs.x, s.y - cs.y), b = SIMD2(d.x - cd.x, d.y - cd.y)
                sxx += a.x * b.x + a.y * b.y
                sxy += a.x * b.y - a.y * b.x
            }
            let th = atan2(sxy, sxx)
            let s = sin(th), c = cos(th)
            return Homography([c, -s, cd.x - (c * cs.x - s * cs.y), s, c, cd.y - (s * cs.x + c * cs.y), 0, 0, 1])
        }
    }

    /// RANSAC over `Motion` models; the refit model and its inlier indices (photocraft `ransac_motion`).
    public static func ransacMotion(_ motion: Motion, src: [SIMD2<Double>], dst: [SIMD2<Double>], iters: Int, threshold: Double, seed: UInt64)
        -> (Homography, [Int])? {
        let k = motion.minPoints, n = src.count
        if n < k { return nil }
        var rng = PhotoKit.Rng(seed ^ 0x5EED_0FA1)
        var best: (Homography, [Int])? = nil
        for _ in 0..<max(iters, 1) {
            var idx: [Int] = []
            if n == k { idx = Array(0..<k) }
            while idx.count < k {
                let i = rng.below(n)
                if !idx.contains(i) { idx.append(i) }
            }
            guard let h = fitMotion(motion, src: idx.map { src[$0] }, dst: idx.map { dst[$0] }) else { continue }
            let inl = Features.inliers(h, src, dst, threshold)
            if best == nil || inl.count > best!.1.count { best = (h, inl) }
        }
        guard let (h, inl) = best, inl.count >= k else { return nil }
        let h2 = fitMotion(motion, src: inl.map { src[$0] }, dst: inl.map { dst[$0] }) ?? h
        let inl2 = Features.inliers(h2, src, dst, threshold)
        return inl2.count >= inl.count ? (h2, inl2) : (h, inl)
    }

    // MARK: - Placement

    /// Where one image lands in the panorama: image px → (undistort) → projection → 2-D motion.
    public struct Placement: Hashable, Sendable {
        public var projection: Projection
        /// Focal length in px (the projection radius).
        public var focal: Double
        /// Projection centre in image px (the image centre).
        public var center: SIMD2<Double>
        /// Radial distortion `k1` on radii normalised by the focal length (0 = none).
        public var k1: Double
        /// Projected coordinates → panorama coordinates.
        public var h: Homography

        public init(projection: Projection, focal: Double, center: SIMD2<Double>, k1: Double, h: Homography) {
            self.projection = projection; self.focal = focal; self.center = center; self.k1 = k1; self.h = h
        }

        /// Image px → projected coordinates (centred, in px of the focal length).
        public func project(_ x: Double, _ y: Double) -> SIMD2<Double> {
            var dx = x - center.x, dy = y - center.y
            if k1 != 0 {
                let s = 1.0 + k1 * (dx * dx + dy * dy) / (focal * focal)
                dx *= s
                dy *= s
            }
            let f = focal
            switch projection {
            case .plane: return SIMD2(dx, dy)
            case .cylinder: return SIMD2(f * atan2(dx, f), f * dy / hypot(dx, f))
            case .sphere: return SIMD2(f * atan2(dx, f), f * atan2(dy, hypot(dx, f)))
            }
        }

        /// Projected → image px (nil outside the valid hemisphere).
        public func unproject(_ a: Double, _ b: Double) -> (Double, Double)? {
            let f = focal
            var dx: Double, dy: Double
            switch projection {
            case .plane:
                dx = a; dy = b
            case .cylinder:
                let th = a / f
                if abs(th) >= 1.55 { return nil }
                dx = f * tan(th); dy = b / cos(th)
            case .sphere:
                let th = a / f, ph = b / f
                if abs(th) >= 1.55 || abs(ph) >= 1.55 { return nil }
                dx = f * tan(th); dy = f * tan(ph) / cos(th)
            }
            if k1 != 0 {
                // Invert r_u = r_d (1 + k1 r_d² / f²) by Newton steps on r_d.
                let ru = hypot(dx, dy)
                if ru > 1e-9 {
                    var rd = ru
                    for _ in 0..<8 {
                        let g = rd * (1.0 + k1 * rd * rd / (f * f)) - ru
                        let dg = 1.0 + 3.0 * k1 * rd * rd / (f * f)
                        if abs(dg) < 1e-9 { break }
                        rd -= g / dg
                    }
                    if !(rd.isFinite && rd > 0) { return nil }
                    dx *= rd / ru
                    dy *= rd / ru
                }
            }
            return (dx + center.x, dy + center.y)
        }

        /// Image px → panorama px.
        public func forward(_ x: Double, _ y: Double) -> (Double, Double) {
            let p = project(x, y)
            return h.apply(p.x, p.y)
        }

        /// Panorama px → image px.
        public func inverse(_ u: Double, _ v: Double) -> (Double, Double)? {
            guard let inv = h.inverse() else { return nil }
            let m = inv.m
            let w = m[6] * u + m[7] * v + m[8]
            if w <= 1e-12 { return nil }
            let (a, b) = inv.apply(u, v)
            return unproject(a, b)
        }

        /// The same placement for images `k×` larger (registration ran at `1/k` scale).
        public func scaled(_ k: Double) -> Placement {
            let s = Homography([k, 0, 0, 0, k, 0, 0, 0, 1])
            let si = Homography([1 / k, 0, 0, 0, 1 / k, 0, 0, 0, 1])
            return Placement(projection: projection, focal: focal * k, center: SIMD2(center.x * k, center.y * k), k1: k1, h: s.mul(h).mul(si))
        }

        /// Shifted in the panorama.
        public func translated(_ dx: Double, _ dy: Double) -> Placement {
            var p = self
            p.h = Homography([1, 0, dx, 0, 1, dy, 0, 0, 1]).mul(h)
            return p
        }

        /// Bounds `[x0, y0, x1, y1]` of a `w × h` image in the panorama (sampled along its edges).
        public func bounds(_ w: Double, _ hgt: Double) -> [Double] {
            var b = [Double.greatestFiniteMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude]
            let n = 32
            for i in 0...n {
                let t = Double(i) / Double(n)
                for (x, y) in [(t * w, 0.0), (t * w, hgt), (0.0, t * hgt), (w, t * hgt)] {
                    let (u, v) = forward(x, y)
                    if u.isFinite && v.isFinite {
                        b = [PhotoKit.dmin(b[0], u), PhotoKit.dmin(b[1], v), PhotoKit.dmax(b[2], u), PhotoKit.dmax(b[3], v)]
                    }
                }
            }
            return b
        }
    }

    // MARK: - Features and pairs

    /// Keypoints and descriptors of one image (registration scale).
    public struct ImageFeatures: Sendable {
        public var w: Int
        public var h: Int
        public var points: [SIMD2<Double>]
        public var desc: [Features.Descriptor]
        public init(w: Int, h: Int, points: [SIMD2<Double>], desc: [Features.Descriptor]) { self.w = w; self.h = h; self.points = points; self.desc = desc }
    }

    /// Detects up to `max` corners of a `w × h` luminance image and describes them.
    public static func detect(width w: Int, height h: Int, luma: [Float], valid: [Bool]? = nil, max maxCount: Int,
                              on backend: Backend = .cpu) throws -> ImageFeatures {
        let minDist = PhotoKit.clamp(Float(Swift.max(w, h)) / 70, 3, 20)
        let corners = try Features.harris(width: w, height: h, luma, max: maxCount, minDist: minDist, valid: valid, on: backend)
        let desc = Features.describe(width: w, height: h, luma, corners: corners, upright: false)
        return ImageFeatures(w: w, h: h, points: corners.map { SIMD2(Double($0.x), Double($0.y)) }, desc: desc)
    }

    /// One image for `detectMany`.
    public struct PreparedImage: Sendable {
        public var w: Int
        public var h: Int
        public var luma: [Float]
        public var valid: [Bool]?
        public init(w: Int, h: Int, luma: [Float], valid: [Bool]? = nil) { self.w = w; self.h = h; self.luma = luma; self.valid = valid }
    }

    /// `detect` for several images in parallel.
    public static func detectMany(_ imgs: [PreparedImage], max maxCount: Int, on backend: Backend = .cpu) throws -> [ImageFeatures] {
        let r: [Result<ImageFeatures, any Error>] = PhotoKit.parMap(imgs.count) { i in
            let im = imgs[i]
            return Result { try detect(width: im.w, height: im.h, luma: im.luma, valid: im.valid, max: maxCount, on: backend) }
        }
        return try r.map { try $0.get() }
    }

    /// A verified image pair: point correspondences (image `a` px, image `b` px).
    public struct PairMatch: Sendable {
        public var a: Int
        public var b: Int
        public var ptsA: [SIMD2<Double>]
        public var ptsB: [SIMD2<Double>]
        /// Homography `b → a` in image px.
        public var homography: Homography
    }

    /// Matches every pair and keeps those passing RANSAC + the Brown–Lowe verification.
    public static func matchPairs(_ feats: [ImageFeatures]) -> [PairMatch] {
        let n = feats.count
        var pairs: [(Int, Int)] = []
        for a in 0..<n { for b in (a + 1)..<max(n, a + 1) { pairs.append((a, b)) } }
        let out: [PairMatch?] = PhotoKit.parMap(pairs.count) { k in
            let (a, b) = pairs[k]
            let fa = feats[a], fb = feats[b]
            if fa.points.count < 6 || fb.points.count < 6 { return nil }
            let m = Features.matchDescriptors(fb.desc, fa.desc, ratio: 0.8)
            if m.count < 8 { return nil }
            let src = m.map { fb.points[$0.0] }, dst = m.map { fa.points[$0.1] }
            let thr = PhotoKit.clamp(Double(max(fa.w, fa.h)) / 300, 1.5, 4)
            guard let (hm, inl) = ransacMotion(.homography, src: src, dst: dst, iters: 1200, threshold: thr, seed: UInt64(a * 131 + b)) else { return nil }
            if Double(inl.count) < 8 + 0.3 * Double(m.count) || inl.count < 10 { return nil }
            return PairMatch(a: a, b: b, ptsA: inl.map { dst[$0] }, ptsB: inl.map { src[$0] }, homography: hm)
        }
        return out.compactMap { $0 }
    }

    /// Focal length (px) of a rotating camera from a homography between two of its images (image
    /// px, centred at `ca` / `cb`), or nil when the homography doesn't constrain it.
    public static func focalFromHomography(_ h: Homography, _ ca: SIMD2<Double>, _ cb: SIMD2<Double>) -> Double? {
        let ta = Homography([1, 0, -ca.x, 0, 1, -ca.y, 0, 0, 1])
        let tb = Homography([1, 0, cb.x, 0, 1, cb.y, 0, 0, 1])
        let m = ta.mul(h).mul(tb).m
        func ok(_ c: (Double, Double)) -> (Double, Double)? {
            let (n, d) = c
            return abs(d) > 1e-12 && n / d > 0 ? (n / d, abs(d)) : nil
        }
        func pick(_ c1: (Double, Double), _ c2: (Double, Double)) -> Double? {
            switch (ok(c1), ok(c2)) {
            case let (a?, b?): return a.1 >= b.1 ? a.0 : b.0
            case let (a?, nil), let (nil, a?): return a.0
            default: return nil
            }
        }
        let f1 = pick((-(m[0] * m[1] + m[3] * m[4]), m[6] * m[7]), (m[1] * m[1] + m[4] * m[4] - m[0] * m[0] - m[3] * m[3], m[6] * m[6] - m[7] * m[7]))
        let f0 = pick((-(m[2] * m[5]), m[0] * m[3] + m[1] * m[4]), (m[5] * m[5] - m[2] * m[2], m[0] * m[0] + m[1] * m[1] - m[3] * m[3] - m[4] * m[4]))
        switch (f0, f1) {
        case let (a?, b?): return (a * b).squareRoot().squareRoot()
        case let (a?, nil), let (nil, a?): return a.squareRoot()
        default: return nil
        }
    }

    // MARK: - Alignment

    /// Options for `align`.
    public struct AlignOptions: Hashable, Sendable {
        public var layout: Layout
        /// Focal length in registration px (EXIF); estimated when nil.
        public var focal: Double?
        /// Image that stays put (nil: the best-connected one).
        public var reference: Int?
        /// Refine a radial distortion coefficient (Geometric Distortion Correction).
        public var geometric: Bool
        public init(layout: Layout, focal: Double? = nil, reference: Int? = nil, geometric: Bool = false) {
            self.layout = layout; self.focal = focal; self.reference = reference; self.geometric = geometric
        }
    }

    /// Result of `align`.
    public struct Alignment: Sendable {
        /// The layout actually used (Auto resolved).
        public var layout: Layout
        public var reference: Int
        /// Per image; nil for images that couldn't be connected.
        public var placements: [Placement?]
        public var focal: Double
        public var k1: Double
        /// Verified pairs `(a, b, inliers)`.
        public var pairs: [(Int, Int, Int)]
        /// RMS reprojection error (px, registration scale) after bundle adjustment.
        public var rms: Double
    }

    struct PairData {
        var a: Int
        var b: Int
        var pa: [SIMD2<Double>]
        var pb: [SIMD2<Double>]
    }

    static func basePlacement(_ f: ImageFeatures, _ projection: Projection, _ focal: Double, _ k1: Double) -> Placement {
        Placement(projection: projection, focal: focal, center: SIMD2(Double(f.w) / 2, Double(f.h) / 2), k1: k1, h: .identity)
    }

    /// Aligns images from their features; nil when fewer than two images connect (photocraft `align`).
    public static func align(_ feats: [ImageFeatures], matches: [PairMatch], options opts: AlignOptions) -> Alignment? {
        let n = feats.count
        if n < 2 || matches.isEmpty { return nil }
        let focal: Double
        if let f = opts.focal, f > 1 {
            focal = f
        } else {
            var fs: [Double] = matches.compactMap { m in
                let fa = feats[m.a], fb = feats[m.b]
                return focalFromHomography(m.homography, SIMD2(Double(fa.w) / 2, Double(fa.h) / 2), SIMD2(Double(fb.w) / 2, Double(fb.h) / 2))
            }.filter(\.isFinite)
            let side = Double(feats.map { max($0.w, $0.h) }.max() ?? 1)
            fs = fs.filter { $0 > side * 0.2 && $0 < side * 20 }
            fs.sort { PhotoKit.totalLess($0, $1) }
            focal = fs.isEmpty ? side : fs[fs.count / 2]
        }
        if opts.layout != .auto { return alignLayout(feats, matches, opts, opts.layout, focal) }
        // Auto: perspective unless too stretched, then cylindrical, or spherical when also tall.
        if var a = alignLayout(feats, matches, opts, .perspective, focal), !tooStretched(feats, a) {
            a.layout = .perspective
            return a
        }
        guard let cyl = alignLayout(feats, matches, opts, .cylindrical, focal) else { return nil }
        var y0 = Double.greatestFiniteMagnitude, y1 = -Double.greatestFiniteMagnitude
        for (p, f) in zip(cyl.placements, feats) {
            if let p {
                let b = p.bounds(Double(f.w), Double(f.h))
                y0 = PhotoKit.dmin(y0, b[1])
                y1 = PhotoKit.dmax(y1, b[3])
            }
        }
        if (y1 - y0) / cyl.focal > 1.4 { return alignLayout(feats, matches, opts, .spherical, cyl.focal) }
        return cyl
    }

    /// A perspective panorama is too stretched when an image grows or shrinks a lot, flips, or the
    /// field of view exceeds about 110°.
    static func tooStretched(_ feats: [ImageFeatures], _ a: Alignment) -> Bool {
        var x0 = Double.greatestFiniteMagnitude, x1 = -Double.greatestFiniteMagnitude
        for (pOpt, f) in zip(a.placements, feats) {
            guard let p = pOpt else { continue }
            let w = Double(f.w), h = Double(f.h)
            let corners = [(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]
            let c = corners.map { p.forward($0.0, $0.1) }
            var area = -0.0
            for i in 0..<4 { area += c[i].0 * c[(i + 1) % 4].1 - c[(i + 1) % 4].0 * c[i].1 }
            area /= 2
            let ratio = area / (w * h)
            if !ratio.isFinite || !(0.3...3.0).contains(ratio) { return true }
            let m = p.h.m
            for (x, y) in corners {
                let q = p.project(x, y)
                if m[6] * q.x + m[7] * q.y + m[8] <= 0 { return true }
            }
            for (u, _) in c { x0 = PhotoKit.dmin(x0, u); x1 = PhotoKit.dmax(x1, u) }
        }
        let fov = 2 * atan((x1 - x0) / 2 / a.focal)
        return fov > PhotoKit.radians(110)
    }

    static func alignLayout(_ feats: [ImageFeatures], _ matches: [PairMatch], _ opts: AlignOptions, _ layout: Layout, _ focal: Double) -> Alignment? {
        let n = feats.count
        let projection = layout.projection, motion = layout.motion
        // Pairwise motions in projected space.
        var pairs: [PairData] = []
        var edges: [(Int, Int, Int, Homography)] = []
        for m in matches {
            let pa = basePlacement(feats[m.a], projection, focal, 0), pb = basePlacement(feats[m.b], projection, focal, 0)
            let qa = m.ptsA.map { pa.project($0.x, $0.y) }, qb = m.ptsB.map { pb.project($0.x, $0.y) }
            let thr = PhotoKit.clamp(Double(max(feats[m.a].w, feats[m.a].h)) / 250, 2, 5)
            guard let (hm, inl) = ransacMotion(motion, src: qb, dst: qa, iters: 600, threshold: thr, seed: UInt64(m.a * 977 + m.b)) else { continue }
            if inl.count < 8 || Double(inl.count) < 0.5 * Double(m.ptsA.count) { continue }
            edges.append((m.a, m.b, inl.count, hm))
            // Bundle adjustment uses at most 80 evenly spread inliers per pair.
            let step = max((inl.count + 79) / 80, 1)
            let sel = stride(from: 0, to: inl.count, by: step).map { inl[$0] }
            pairs.append(PairData(a: m.a, b: m.b, pa: sel.map { m.ptsA[$0] }, pb: sel.map { m.ptsB[$0] }))
        }
        if edges.isEmpty { return nil }
        var degree = [Int](repeating: 0, count: n)
        for e in edges { degree[e.0] += e.2; degree[e.1] += e.2 }
        let reference: Int
        if let r = opts.reference, r < n, r >= 0 {
            reference = r
        } else {
            // Best connected; ties go to the middle image (Rust `max_by`: the last of equals).
            func cmp(_ i: Int, _ j: Int) -> Int {
                if degree[i] != degree[j] { return degree[i] < degree[j] ? -1 : 1 }
                let di = abs(i - n / 2), dj = abs(j - n / 2)
                return dj < di ? -1 : (dj > di ? 1 : 0)
            }
            var best = 0
            for i in 1..<n where cmp(best, i) <= 0 { best = i }
            reference = best
        }
        // Maximum spanning tree (Prim) from the reference; transforms map projected → panorama.
        var tf = [Homography?](repeating: nil, count: n)
        let rc = SIMD2(Double(feats[reference].w) / 2, Double(feats[reference].h) / 2)
        tf[reference] = Homography([1, 0, rc.x, 0, 1, rc.y, 0, 0, 1])
        while true {
            var best: (Int, Int, Homography)? = nil
            for e in edges {
                var cand: (Int, Homography)? = nil
                if let ta = tf[e.0], tf[e.1] == nil {
                    cand = (e.1, ta.mul(e.3))
                } else if tf[e.0] == nil, let tb = tf[e.1] {
                    cand = e.3.inverse().map { (e.0, tb.mul($0)) }
                }
                if let (node, t) = cand, best == nil || e.2 > best!.1 { best = (node, e.2, t) }
            }
            guard let (node, _, t) = best else { break }
            tf[node] = t
        }
        let placed = (0..<n).filter { tf[$0] != nil }
        if placed.count < 2 { return nil }
        // Bundle adjustment (Levenberg–Marquardt, numeric Jacobian).
        let movable = placed.filter { $0 != reference }
        let mp = motion.nParams
        let refineFocal = projection != .plane
        let nGlob = (opts.geometric ? 1 : 0) + (refineFocal ? 1 : 0)
        var params: [Double] = movable.flatMap { motion.toParams(tf[$0]!) }
        if opts.geometric { params.append(0) }
        if refineFocal { params.append(log(focal)) }
        let nPar = params.count
        let movableIndex: [Int: Int] = Dictionary(uniqueKeysWithValues: movable.enumerated().map { ($1, $0) })
        let tfRef = tf[reference]!
        func decode(_ p: [Double]) -> [Placement?] {
            let k1 = opts.geometric ? p[movable.count * mp] : 0
            let f = refineFocal ? exp(p[nPar - 1]) : focal
            return (0..<n).map { i in
                let h: Homography
                if i == reference {
                    h = tfRef
                } else {
                    guard let k = movableIndex[i] else { return nil }
                    h = motion.toHomography(p[(k * mp)..<((k + 1) * mp)])
                }
                var pl = basePlacement(feats[i], projection, f, k1)
                pl.h = h
                return pl
            }
        }
        func residuals(_ p: [Double]) -> [Double] {
            let pl = decode(p)
            var r: [Double] = []
            for pd in pairs {
                guard let a = pl[pd.a], let b = pl[pd.b] else { continue }
                for (qa, qb) in zip(pd.pa, pd.pb) {
                    let (ua, va) = a.forward(qa.x, qa.y)
                    let (ub, vb) = b.forward(qb.x, qb.y)
                    r.append(ua - ub)
                    r.append(va - vb)
                }
            }
            if opts.geometric { r.append(p[movable.count * mp] * 20) }
            if refineFocal { r.append((p[nPar - 1] - log(focal)) * 2) }
            return r
        }
        func cost(_ r: ArraySlice<Double>) -> Double { var s = -0.0; for v in r { s += v * v }; return s }
        var cur = residuals(params)
        var lambda = 1e-3
        if nPar > 0 && !movable.isEmpty {
            for _ in 0..<40 {
                let mRes = cur.count
                let snapshot = params
                let cols: [[Double]] = PhotoKit.parMap(nPar) { j in
                    let step = 1e-6 * (1 + abs(snapshot[j]))
                    var pp = snapshot
                    pp[j] += step
                    let rp = residuals(pp)
                    pp[j] -= 2.0 * step
                    let rm = residuals(pp)
                    return (0..<mRes).map { (rp[$0] - rm[$0]) / (2.0 * step) }
                }
                var jtj = [Double](repeating: 0, count: nPar * nPar)
                var jtr = [Double](repeating: 0, count: nPar)
                for a in 0..<nPar {
                    var s = -0.0
                    for (jv, rv) in zip(cols[a], cur) { s += jv * rv }
                    jtr[a] = -s
                    for b in a..<nPar {
                        var v = -0.0
                        for (x, y) in zip(cols[a], cols[b]) { v += x * y }
                        jtj[a * nPar + b] = v
                        jtj[b * nPar + a] = v
                    }
                }
                var improved = false
                for _ in 0..<8 {
                    var a = jtj
                    for d in 0..<nPar { a[d * nPar + d] += lambda * (jtj[d * nPar + d] + 1e-9) }
                    guard let delta = NormalEquations.solveDense(nPar, a, jtr) else {
                        lambda *= 10
                        continue
                    }
                    let trial = zip(params, delta).map { $0 + $1 }
                    let rt = residuals(trial)
                    if cost(rt[...]) < cost(cur[...]) {
                        let gain = cost(cur[...]) - cost(rt[...])
                        params = trial
                        cur = rt
                        lambda = PhotoKit.dmax(lambda * 0.3, 1e-9)
                        improved = gain > 1e-10 * PhotoKit.dmax(cost(cur[...]), 1e-12)
                        break
                    }
                    lambda *= 10
                }
                if !improved { break }
            }
        }
        let placements = decode(params)
        let nRes = max(pairs.reduce(0) { $0 + $1.pa.count }, 1)
        let rms = (cost(cur[0..<min(cur.count - nGlob, cur.count)]) / Double(nRes)).squareRoot()
        let k1 = opts.geometric ? params[movable.count * mp] : 0
        let outFocal = refineFocal ? exp(params[nPar - 1]) : focal
        return Alignment(layout: layout, reference: reference, placements: placements, focal: outFocal, k1: k1,
                         pairs: edges.map { ($0.0, $0.1, $0.2) }, rms: rms)
    }

    // MARK: - Photometric

    /// One image warped into the panorama: an axis-aligned region with colour channels and coverage.
    public struct RoiImage: Sendable {
        public var x0: Int32
        public var y0: Int32
        public var w: Int
        public var h: Int
        /// Colour channels per pixel (no alpha).
        public var ch: Int
        public var px: [Float]
        /// Coverage 0…1.
        public var alpha: [Float]
        public init(x0: Int32, y0: Int32, w: Int, h: Int, ch: Int, px: [Float], alpha: [Float]) {
            self.x0 = x0; self.y0 = y0; self.w = w; self.h = h; self.ch = ch; self.px = px; self.alpha = alpha
        }

        func at(_ x: Int32, _ y: Int32) -> Int? {
            let lx = Int(x) - Int(x0), ly = Int(y) - Int(y0)
            return lx >= 0 && ly >= 0 && lx < w && ly < h ? ly * w + lx : nil
        }
    }

    /// Gains (per image, per channel) and the vignetting model found by `photometric`.
    public struct Photometric: Hashable, Sendable {
        public var gains: [[Float]]
        /// `log V(r) = a·r² + b·r⁴`, `r` = distance from the image centre over the half diagonal.
        public var vignette: [Double]

        /// Multiplier that corrects a pixel of image `i` at normalised squared radius `r2`.
        public func factor(_ i: Int, _ c: Int, _ r2: Double) -> Float {
            let v = exp(vignette[0] * r2 + vignette[1] * r2 * r2)
            return Float(1.0 / (Double(gains[i][c]) * v))
        }
    }

    /// Estimates exposure gains and a shared vignetting falloff from the overlaps of `imgs`
    /// (`geometry`: placements and source sizes, for each panorama pixel's source radius; without
    /// it the vignetting is not estimated) (photocraft `photometric`).
    public static func photometric(_ imgs: [RoiImage], geometry: ([Placement], [(Int, Int)])?, gain: Bool, vignette vig0: Bool) -> Photometric {
        let vignette = vig0 && geometry != nil
        let n = imgs.count
        let ch = imgs.first?.ch ?? 1
        let identity = Photometric(gains: [[Float]](repeating: [Float](repeating: 1, count: ch), count: n), vignette: [0, 0])
        if n == 0 || (!gain && !vignette) { return identity }
        var x0 = Int32.max, y0 = Int32.max, x1 = Int32.min, y1 = Int32.min
        for im in imgs {
            x0 = min(x0, im.x0); y0 = min(y0, im.y0)
            x1 = max(x1, im.x0 &+ Int32(im.w)); y1 = max(y1, im.y0 &+ Int32(im.h))
        }
        let area = Int64(x1 - x0) * Int64(y1 - y0)
        let step = Int32(Double(max(area / 40_000, 1)).squareRoot().rounded(.up))
        func r2Of(_ i: Int, _ u: Int32, _ v: Int32) -> Double? {
            guard let (placements, sizes) = geometry else { return 0 }
            guard let (sx, sy) = placements[i].inverse(Double(u) + 0.5, Double(v) + 0.5) else { return nil }
            let w = Double(sizes[i].0), h = Double(sizes[i].1)
            let dx = sx - w / 2, dy = sy - h / 2
            return (dx * dx + dy * dy) / (w * w / 4 + h * h / 4)
        }
        struct Sample { var a: Int; var b: Int; var ca: [Float]; var cb: [Float]; var ra: Double; var rb: Double }
        var samples: [Sample] = []
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                var cover: [(Int, Int)] = []
                for i in 0..<n { if let k = imgs[i].at(x, y), imgs[i].alpha[k] > 0.999 { cover.append((i, k)) } }
                for p in 0..<cover.count {
                    for q in (p + 1)..<max(cover.count, p + 1) {
                        let (a, ka) = cover[p], (b, kb) = cover[q]
                        let ca = Array(imgs[a].px[(ka * ch)..<((ka + 1) * ch)]), cb = Array(imgs[b].px[(kb * ch)..<((kb + 1) * ch)])
                        if (ca + cb).contains(where: { !(0.02...0.98).contains($0) }) { continue }
                        // Disagreeing content (parallax, moving objects) says nothing about exposure.
                        if zip(ca, cb).contains(where: { abs(logf($0 / $1)) > 1 }) { continue }
                        guard let ra = r2Of(a, x, y), let rb = r2Of(b, x, y) else { continue }
                        samples.append(Sample(a: a, b: b, ca: ca, cb: cb, ra: ra, rb: rb))
                    }
                }
                x = x &+ step
            }
            y = y &+ step
        }
        if samples.count < 20 { return identity }
        let sigmaN = 0.05
        let sigmaG = gain ? 0.15 : 1e-4
        var out = identity
        let nv = vignette ? 2 : 0
        // Vignetting is solved on the channel mean, then gains per channel with it fixed.
        var ne = NormalEquations(n + nv)
        for s in samples {
            var la = -0.0, lb = -0.0
            for v in s.ca { la += log(Double(v)) }
            for v in s.cb { lb += log(Double(v)) }
            la /= Double(ch); lb /= Double(ch)
            var row: [(Int, Double)] = [(s.a, 1), (s.b, -1)]
            if vignette {
                row.append((n, s.ra - s.rb))
                row.append((n + 1, s.ra * s.ra - s.rb * s.rb))
            }
            ne.add(row, la - lb, 1.0 / sigmaN)
        }
        for i in 0..<n { ne.add([(i, 1)], 0, 1.0 / sigmaG) }
        if vignette {
            ne.add([(n, 1)], 0, 0.5)
            ne.add([(n + 1, 1)], 0, 0.5)
        }
        guard let sol = ne.solve() else { return out }
        if vignette { out.vignette = [PhotoKit.clamp(sol[n], -2, 0.5), PhotoKit.clamp(sol[n + 1], -2, 2)] }
        if gain {
            for c in 0..<ch {
                var ne = NormalEquations(n)
                for s in samples {
                    let va = out.vignette[0] * s.ra + out.vignette[1] * s.ra * s.ra
                    let vb = out.vignette[0] * s.rb + out.vignette[1] * s.rb * s.rb
                    ne.add([(s.a, 1), (s.b, -1)], (log(Double(s.ca[c])) - va) - (log(Double(s.cb[c])) - vb), 1.0 / sigmaN)
                }
                for i in 0..<n { ne.add([(i, 1)], 0, 1.0 / sigmaG) }
                if let g = ne.solve() {
                    for i in 0..<n { out.gains[i][c] = Float(PhotoKit.clamp(exp(g[i]), 0.2, 5)) }
                }
            }
        }
        return out
    }

    // MARK: - Seams

    /// Seam labels on a `w × h` grid (−1 = no image): images are added in `order`; each new image
    /// takes the part of its overlap with the composite on its side of the cheapest path through
    /// the overlap (cost = luminance difference) (photocraft `seam_labels`).
    public static func seamLabels(width w: Int, height h: Int, luma: [[Float]], cover: [[Bool]], order: [Int]) -> [Int32] {
        var label = [Int32](repeating: -1, count: w * h)
        let none = Int.max
        for img in order {
            let cov = cover[img]
            var overlap = [Bool](repeating: false, count: w * h)
            var sx = 0.0, sy = 0.0, no = 0, nx = 0.0, ny = 0.0, nn = 0
            for i in 0..<(w * h) where cov[i] {
                nx += Double(i % w); ny += Double(i / w); nn += 1
                if label[i] >= 0 {
                    overlap[i] = true
                    sx += Double(i % w); sy += Double(i / w); no += 1
                } else {
                    label[i] = Int32(img)
                }
            }
            if no == 0 { continue }
            let cx = nx / Double(nn), cy = ny / Double(nn)
            let ox: Double, oy: Double
            if nn == no {
                // Wholly inside the composite (photocraft #5745: two photos in one document, the
                // second moved by Auto-Align so the canvas crops it to the part over the first).
                // Its side of the seam is the one it lies towards from the composite's centre; an
                // image centred on the composite has no side, and the earlier images keep it.
                var px = 0.0, py = 0.0, pn = 0
                for i in 0..<(w * h) where label[i] >= 0 {
                    px += Double(i % w); py += Double(i / w); pn += 1
                }
                px /= Double(max(pn, 1)); py /= Double(max(pn, 1))
                if abs(cx - px) < 0.5 && abs(cy - py) < 0.5 { continue }
                (ox, oy) = (px, py)
            } else {
                (ox, oy) = (sx / Double(no), sy / Double(no))
            }
            let vertical = abs(cx - ox) >= abs(cy - oy)
            let positive = vertical ? cx > ox : cy > oy
            let li = luma[img]
            func cost(_ i: Int) -> Float { 0.002 + abs(li[i] - luma[Int(label[i])][i]) }
            let (lines, len) = vertical ? (h, w) : (w, h)
            @inline(__always) func idx(_ line: Int, _ k: Int) -> Int { vertical ? line * w + k : k * w + line }
            var acc = [Float](repeating: .infinity, count: w * h)
            var from = [Int](repeating: none, count: w * h)
            var prevLine: Int? = nil
            for line in 0..<lines {
                if !(0..<len).contains(where: { overlap[idx(line, $0)] }) { continue }
                for k in 0..<len {
                    let i = idx(line, k)
                    if !overlap[i] { continue }
                    var best: (Float, Int) = (0, none)
                    if let pl = prevLine, pl + 1 == line {
                        best = (.infinity, none)
                        for dk in -1...1 {
                            let kk = k + dk
                            if kk < 0 || kk >= len { continue }
                            let j = idx(pl, kk)
                            if acc[j] < best.0 { best = (acc[j], kk) }
                        }
                        if best.1 == none { best = (0, none) }
                    }
                    acc[i] = best.0 + cost(i)
                    from[i] = best.1
                }
                prevLine = line
            }
            // Backtrack from the cheapest end; lines not reached keep their own best cell.
            var seam = [Int](repeating: none, count: lines)
            var line = lines
            while line > 0 {
                line -= 1
                if seam[line] != none { continue }
                var kBest: Int? = nil
                for k in 0..<len where overlap[idx(line, k)] {
                    if kBest == nil || PhotoKit.totalLess(acc[idx(line, k)], acc[idx(line, kBest!)]) { kBest = k }
                }
                guard var k = kBest else { continue }
                var l = line
                while true {
                    seam[l] = k
                    let f = from[idx(l, k)]
                    if f == none || l == 0 { break }
                    l -= 1
                    if seam[l] != none { break }
                    k = f
                }
            }
            for line in 0..<lines {
                let s = seam[line]
                if s == none { continue }
                for k in 0..<len {
                    let i = idx(line, k)
                    if overlap[i] && ((positive && k > s) || (!positive && k < s)) { label[i] = Int32(img) }
                }
            }
        }
        return label
    }

    // MARK: - Multi-band blending

    /// Number of pyramid levels `multiband` uses for a seam mask of this size.
    public static func blendLevels(width w: Int, height h: Int) -> Int {
        var s = min(w, h), n = 1
        while s > 16 && n < 7 { s /= 2; n += 1 }
        return n
    }

    /// 5-tap binomial (integer weights, then /16) + decimation (photocraft panorama `reduce`).
    static func reduce(_ w: Int, _ h: Int, _ ch: Int, _ src: [Float]) -> (Int, Int, [Float]) {
        let nw = (w + 1) / 2, nh = (h + 1) / 2
        let kv: [Float] = [1, 4, 6, 4, 1]
        var tmp = [Float](repeating: 0, count: nw * h * ch)
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                let sp = UnsafeSendable(s.baseAddress!), tp = UnsafeSendable(t.baseAddress!)
                PhotoKit.parRows(h) { y in
                    for x in 0..<nw {
                        for c in 0..<ch {
                            var acc: Float = 0
                            for t in 0..<5 {
                                let xx = min(max(2 * x + t - 2, 0), w - 1)
                                acc += kv[t] * sp.value[(y * w + xx) * ch + c]
                            }
                            tp.value[(y * nw + x) * ch + c] = acc / 16
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: nw * nh * ch)
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                let tp = UnsafeSendable(t.baseAddress!), op = UnsafeSendable(o.baseAddress!)
                PhotoKit.parRows(nh) { y in
                    for x in 0..<nw {
                        for c in 0..<ch {
                            var acc: Float = 0
                            for t in 0..<5 {
                                let yy = min(max(2 * y + t - 2, 0), h - 1)
                                acc += kv[t] * tp.value[(yy * nw + x) * ch + c]
                            }
                            op.value[(y * nw + x) * ch + c] = acc / 16
                        }
                    }
                }
            }
        }
        return (nw, nh, out)
    }

    /// Bilinear upsampling at half-pixel-aligned positions (photocraft panorama `expand`).
    static func expand(_ sw: Int, _ sh: Int, _ ch: Int, _ src: [Float], _ w: Int, _ h: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h * ch)
        if sw == 0 || sh == 0 { return out }
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                let sp = UnsafeSendable(s.baseAddress!), op = UnsafeSendable(o.baseAddress!)
                PhotoKit.parRows(h) { y in
                    let fy = PhotoKit.clamp((Float(y) + 0.5) / 2 - 0.5, 0, Float(sh - 1))
                    let y0 = PhotoKit.usize(fy.rounded(.down)), ty = fy - fy.rounded(.down)
                    let y1 = min(y0 + 1, sh - 1)
                    for x in 0..<w {
                        let fx = PhotoKit.clamp((Float(x) + 0.5) / 2 - 0.5, 0, Float(sw - 1))
                        let x0 = PhotoKit.usize(fx.rounded(.down)), tx = fx - fx.rounded(.down)
                        let x1 = min(x0 + 1, sw - 1)
                        for c in 0..<ch {
                            @inline(__always) func p(_ xx: Int, _ yy: Int) -> Float { sp.value[(yy * sw + xx) * ch + c] }
                            let top = p(x0, y0) + (p(x1, y0) - p(x0, y0)) * tx
                            let bot = p(x0, y1) + (p(x1, y1) - p(x0, y1)) * tx
                            op.value[(y * w + x) * ch + c] = top + (bot - top) * ty
                        }
                    }
                }
            }
        }
        return out
    }

    /// Fills pixels with zero `wt` from their surroundings (push-pull), so pyramid levels don't
    /// pull in black from outside an image.
    static func pushPull(_ w: Int, _ h: Int, _ ch: Int, _ px: inout [Float], _ wt: [Float]) {
        if w <= 1 && h <= 1 { return }
        let nw = (w + 1) / 2, nh = (h + 1) / 2
        var cpx = [Float](repeating: 0, count: nw * nh * ch)
        var cw = [Float](repeating: 0, count: nw * nh)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x, j = (y / 2) * nw + x / 2
                let a = wt[i]
                cw[j] += a
                for c in 0..<ch { cpx[j * ch + c] += a * px[i * ch + c] }
            }
        }
        for j in 0..<(nw * nh) where cw[j] > 0 {
            for c in 0..<ch { cpx[j * ch + c] /= cw[j] }
            cw[j] = 1
        }
        if cw.contains(0) && cw.contains(where: { $0 > 0 }) { pushPull(nw, nh, ch, &cpx, cw) }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if wt[i] < 1 {
                    let j = (y / 2) * nw + x / 2
                    let a = wt[i]
                    for c in 0..<ch { px[i * ch + c] = a * px[i * ch + c] + (1 - a) * cpx[j * ch + c] }
                }
            }
        }
    }

    /// The grid one image is blended on: its ROI grown by a margin, aligned to the coarsest level.
    static func bandGrid(_ im: RoiImage, _ w: Int, _ h: Int, _ levels: Int) -> (gx0: Int32, gy0: Int32, gw: Int, gh: Int) {
        let align = Int32(1) << Int32(levels - 1)
        let margin = align &* 4
        let gx0 = (max(im.x0 &- margin, 0) / align) &* align
        let gy0 = (max(im.y0 &- margin, 0) / align) &* align
        let gx1 = min(im.x0 &+ Int32(im.w) &+ margin, Int32(clamping: w))
        let gy1 = min(im.y0 &+ Int32(im.h) &+ margin, Int32(clamping: h))
        return (gx0, gy0, Int(max(gx1 - gx0, 1)), Int(max(gy1 - gy0, 1)))
    }

    /// One image's colours, coverage and weights on its band grid (colours push-pulled into the
    /// uncovered pixels).
    static func bandInputs(_ im: RoiImage, _ weight: [Float], _ g: (gx0: Int32, gy0: Int32, gw: Int, gh: Int), _ ch: Int) -> (px: [Float], cov: [Float], wt: [Float]) {
        let (gx0, gy0, gw, gh) = g
        var px = [Float](repeating: 0, count: gw * gh * ch)
        var cov = [Float](repeating: 0, count: gw * gh)
        var wt = [Float](repeating: 0, count: gw * gh)
        px.withUnsafeMutableBufferPointer { pb in
            cov.withUnsafeMutableBufferPointer { cb in
                wt.withUnsafeMutableBufferPointer { wb in
                    im.px.withUnsafeBufferPointer { ipx in
                        im.alpha.withUnsafeBufferPointer { ia in
                            weight.withUnsafeBufferPointer { iw in
                                let pp = UnsafeSendable(pb.baseAddress!), cp = UnsafeSendable(cb.baseAddress!), wp = UnsafeSendable(wb.baseAddress!)
                                let sp = UnsafeSendable(ipx), ap = UnsafeSendable(ia), kp = UnsafeSendable(iw)
                                // Each ROI row lands on its own grid row: rows run in parallel.
                                PhotoKit.parRows(im.h) { y in
                                    let gy = Int(im.y0) + y - Int(gy0)
                                    if gy < 0 || gy >= gh { return }
                                    for x in 0..<im.w {
                                        let gx = Int(im.x0) + x - Int(gx0)
                                        if gx < 0 || gx >= gw { continue }
                                        let i = y * im.w + x, gi = gy * gw + gx
                                        cp.value[gi] = ap.value[i]
                                        wp.value[gi] = kp.value[i] * PhotoKit.fmin(ap.value[i], 1)
                                        for c in 0..<ch { pp.value[gi * ch + c] = sp.value[i * ch + c] }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return (px, cov, wt)
    }

    /// The panorama's coverage: the union (max) of the images' alpha.
    static func coverage(_ w: Int, _ h: Int, _ imgs: [RoiImage]) -> [Float] {
        var cov = [Float](repeating: 0, count: w * h)
        cov.withUnsafeMutableBufferPointer { cb in
            let cp = UnsafeSendable(cb.baseAddress!)
            for im in imgs {
                im.alpha.withUnsafeBufferPointer { ab in
                    let ap = UnsafeSendable(ab)
                    // Images in order, rows of one image in parallel (disjoint pixels).
                    PhotoKit.parRows(im.h) { y in
                        let py = Int(im.y0) + y
                        if py < 0 || py >= h { return }
                        for x in 0..<im.w {
                            let px = Int(im.x0) + x
                            if px < 0 || px >= w { continue }
                            let p = py * w + px
                            cp.value[p] = PhotoKit.fmax(cp.value[p], ap.value[y * im.w + x])
                        }
                    }
                }
            }
        }
        return cov
    }

    /// Multi-band blend of `imgs` into a `w × h` panorama (origin 0, 0) with one weight map per
    /// image over its ROI. Returns the colour channels (`ch` per pixel) and the total coverage
    /// (photocraft `multiband`).
    public static func multiband(width w: Int, height h: Int, images imgs: [RoiImage], weights: [[Float]], levels: Int,
                                 on backend: Backend = .auto) throws -> (px: [Float], coverage: [Float]) {
        let ch = imgs.first?.ch ?? 1
        return try PhotoKit.run(backend, "Panorama.multiband \(w)×\(h)", fits: PhotoKit.gpuFits(w, h, ch),
                                gpu: { try PanoramaGPU.multiband(w, h, imgs, weights, max(levels, 1)) },
                                cpu: { multibandCPU(w, h, imgs, weights, levels) })
    }

    static func multibandCPU(_ w: Int, _ h: Int, _ imgs: [RoiImage], _ weights: [[Float]], _ levels0: Int) -> ([Float], [Float]) {
        let ch = imgs.first?.ch ?? 1
        let levels = max(levels0, 1)
        var sizes = [(w, h)]
        for _ in 1..<max(levels, 1) {
            let (pw, ph) = sizes[sizes.count - 1]
            sizes.append(((pw + 1) / 2, (ph + 1) / 2))
        }
        var acc: [[Float]] = sizes.map { [Float](repeating: 0, count: $0.0 * $0.1 * ch) }
        var wsum: [[Float]] = sizes.map { [Float](repeating: 0, count: $0.0 * $0.1) }
        typealias Band = (gx0: Int32, gy0: Int32, lap: [(Int, Int, [Float])], gau: [[Float]])
        let bands: [Band] = PhotoKit.parMap(imgs.count) { k in
            let im = imgs[k]
            let g = bandGrid(im, w, h, levels)
            var (px, cov, wt) = bandInputs(im, weights[k], g, ch)
            let bin = cov.map { $0 > 0.5 ? Float(1) : 0 }
            pushPull(g.gw, g.gh, ch, &px, bin)
            var lap: [(Int, Int, [Float])] = []
            var gau: [[Float]] = []
            var cw = g.gw, chh = g.gh, cur = px, cwt = wt
            for l in 0..<levels {
                if l + 1 == levels {
                    lap.append((cw, chh, cur))
                    gau.append(cwt)
                    break
                }
                let (nw, nh, down) = reduce(cw, chh, ch, cur)
                let up = expand(nw, nh, ch, down, cw, chh)
                lap.append((cw, chh, Pyramid.zipMap(cur, up, -)))
                gau.append(cwt)
                let (_, _, wdown) = reduce(cw, chh, 1, cwt)
                cw = nw; chh = nh; cur = down; cwt = wdown
            }
            return (g.gx0, g.gy0, lap, gau)
        }
        for band in bands {
            for (l, ((lw, lh, bp), g)) in zip(band.lap, band.gau).enumerated() {
                let ox = Int(band.gx0 >> Int32(l)), oy = Int(band.gy0 >> Int32(l))
                let (pw, ph) = sizes[l]
                for y in 0..<lh {
                    let py = oy + y
                    if py >= ph { break }
                    for x in 0..<lw {
                        let px = ox + x
                        if px >= pw { break }
                        let i = y * lw + x, p = py * pw + px
                        let k = g[i]
                        if k <= 0 { continue }
                        wsum[l][p] += k
                        for c in 0..<ch { acc[l][p * ch + c] += k * bp[i * ch + c] }
                    }
                }
            }
        }
        for l in 0..<levels {
            let (pw, ph) = sizes[l]
            for p in 0..<(pw * ph) {
                let k = wsum[l][p]
                for c in 0..<ch { acc[l][p * ch + c] = k > 1e-8 ? acc[l][p * ch + c] / k : 0 }
            }
        }
        var cur = acc.removeLast()
        if levels >= 2 {
            for l in stride(from: levels - 2, through: 0, by: -1) {
                let (pw, ph) = sizes[l], (sw, sh) = sizes[l + 1]
                let up = expand(sw, sh, ch, cur, pw, ph)
                cur = Pyramid.zipMap(acc[l], up, +)
            }
        }
        return (cur, coverage(w, h, imgs))
    }

    // MARK: - Warping (photo_cmds glue)

    /// The projective matrix of a planar, distortion-free placement (surface px → panorama px);
    /// image coordinates are surface coordinates minus `origin` (photocraft engine `plane_matrix`).
    public static func planeMatrix(_ pl: Placement, origin: SIMD2<Double>) -> Homography? {
        guard pl.projection == .plane && pl.k1 == 0 else { return nil }
        let t = Homography([1, 0, -pl.center.x - origin.x, 0, 1, -pl.center.y - origin.y, 0, 0, 1])
        return pl.h.mul(t)
    }

    /// Warps the content of `surface` inside `rect` into the panorama by `placement` shifted by
    /// `offset` (image coordinates are surface coordinates minus `origin`): a `Transform` warp for
    /// planar placements, a `MeshWarp` through `Placement.forward` otherwise (photocraft engine
    /// `warp_placed`).
    public static func warpPlaced(_ surface: Surface, rect: PixelRect, origin: SIMD2<Double>, placement: Placement, offset: SIMD2<Double>,
                                  interp: Interp = .bicubic, on backend: Backend = .auto) -> Surface {
        let pl = placement.translated(offset.x, offset.y)
        if let h = planeMatrix(pl, origin: origin) {
            return Transform.warpSurface(surface, srcRect: rect, h: h, interp: interp, on: backend)
        }
        return MeshWarp.warpMeshSurface(surface, srcRect: rect, map: { x, y in pl.forward(x - origin.x, y - origin.y) }, interp: interp, on: backend)
    }
}
