// CoreGraphics bridges for PCDocument's path model (`VectorPath`, `Subpath`, `Knot`) and the
// path generator for its live shapes (`LiveShape`).
// Replaces photocraft-vector's path plumbing (crates/vector/src/{flatten,shapes}.rs: Bézier
// flattening, `live_path`) with CGPath. Port of its API shape, MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.
//
// The model is PCDocument's (photocraft `doc::vector`): document pixels, y down, cubic Bézier.

import CoreGraphics
import Foundation
import PCDocument

extension Subpath {
    /// Appends this subpath to `p`; straight segments (retracted handles) become lines, so strokes
    /// get true joins and caps on them.
    func add(to p: CGMutablePath) {
        guard let first = knots.first else { return }
        p.move(to: first.anchor.cgPoint)
        for s in segments {
            if s[1] == s[0] && s[2] == s[3] { p.addLine(to: s[3].cgPoint) }
            else { p.addCurve(to: s[3].cgPoint, control1: s[1].cgPoint, control2: s[2].cgPoint) }
        }
        if closed { p.closeSubpath() }
    }
}

extension VectorPath {
    /// Every subpath as one CGPath, without path operations (what a stroke follows).
    public var cgPath: CGPath {
        let p = CGMutablePath()
        for s in subpaths { s.add(to: p) }
        return p
    }

    /// The subpaths in `range` as one CGPath.
    public func cgPath(_ range: Range<Int>) -> CGPath {
        let p = CGMutablePath()
        for s in subpaths[range] { s.add(to: p) }
        return p
    }

    /// Bounds of anchors and control points as a CGRect.
    public var controlRect: CGRect? {
        controlBounds.map { CGRect(x: $0.x, y: $0.y, width: $0.z - $0.x, height: $0.w - $0.y) }
    }

    /// A path from a CGPath (quadratic segments raised to cubic). The subpaths form one shape
    /// component filled with `fillRule` (the first combines, the rest `join` it), which is how a
    /// CGPath fills: glyph counters and boolean-operation holes stay holes.
    public init(cgPath: CGPath, fillRule: FillRule = .nonZero) {
        var subs: [Subpath] = []
        var cur: [Knot] = []
        var start = CGPoint.zero
        func k(_ p: CGPoint) -> Knot { let q = PCPoint(p); return Knot(anchor: q, inCtrl: q, outCtrl: q) }
        func flush(closed: Bool) {
            if !cur.isEmpty {
                var knots = cur
                // A closing segment that ends on the first anchor folds into it.
                if closed, knots.count > 1, let l = knots.last, l.anchor == knots[0].anchor {
                    knots[0].inCtrl = l.inCtrl
                    knots.removeLast()
                }
                subs.append(Subpath(closed: closed, knots: knots))
            }
            cur = []
        }
        cgPath.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                flush(closed: false)
                start = e.points[0]
                cur = [k(start)]
            case .addLineToPoint:
                cur.append(k(e.points[0]))
            case .addQuadCurveToPoint:
                let q = e.points[0], p = e.points[1]
                let p0 = cur.last?.anchor.cgPoint ?? start
                let c1 = CGPoint(x: p0.x + 2 / 3 * (q.x - p0.x), y: p0.y + 2 / 3 * (q.y - p0.y))
                let c2 = CGPoint(x: p.x + 2 / 3 * (q.x - p.x), y: p.y + 2 / 3 * (q.y - p.y))
                if !cur.isEmpty { cur[cur.count - 1].outCtrl = PCPoint(c1) }
                cur.append(Knot(anchor: PCPoint(p), inCtrl: PCPoint(c2), outCtrl: PCPoint(p)))
            case .addCurveToPoint:
                if !cur.isEmpty { cur[cur.count - 1].outCtrl = PCPoint(e.points[0]) }
                cur.append(Knot(anchor: PCPoint(e.points[2]), inCtrl: PCPoint(e.points[1]), outCtrl: PCPoint(e.points[2])))
            case .closeSubpath:
                flush(closed: true)
            @unknown default: break
            }
        }
        flush(closed: false)
        for i in subs.indices.dropFirst() { subs[i].op = .join }
        self.init(subs, fillRule: fillRule)
    }
}

extension LiveShape {
    /// Handle length of a quarter-circle cubic, 4/3·(√2 − 1) (photocraft `KAPPA`).
    public static let kappa = 0.552_284_749_830_793_4

    /// Clamps radii `[tl, tr, br, bl]` so adjacent radii never exceed a side (CSS border-radius
    /// rule; photocraft `clamp_radii`).
    public static func clampRadii(width w: Double, height h: Double, _ radii: SIMD4<Double>) -> SIMD4<Double> {
        let r = SIMD4(max(radii.x, 0), max(radii.y, 0), max(radii.z, 0), max(radii.w, 0))
        var f = 1.0
        for (a, b, side) in [(r.x, r.y, w), (r.y, r.z, h), (r.z, r.w, w), (r.w, r.x, h)] where a + b > side && a + b > 0 {
            f = min(f, side / (a + b))
        }
        return r * f
    }

    /// The path of the live shape (photocraft `live_path`); knots run clockwise on screen from the
    /// top.
    public var path: VectorPath {
        switch self {
        case .rect(let r, let radii): Self.roundedRect(r.x, r.y, r.z, r.w, radii)
        case .ellipse(let r): Self.ellipse(r.x, r.y, r.z, r.w)
        case .polygon(let r, let sides, let ratio): Self.polygon(r.x, r.y, r.z, r.w, Int(sides), ratio)
        case .line(let a, let b, let weight): Self.line(a, b, weight)
        }
    }

    static func roundedRect(_ x: Double, _ y: Double, _ w0: Double, _ h0: Double, _ radii: SIMD4<Double>) -> VectorPath {
        let w = abs(w0), h = abs(h0)
        let rr = clampRadii(width: w, height: h, radii)
        let (tl, tr, br, bl) = (rr.x, rr.y, rr.z, rr.w)
        if tl <= 0 && tr <= 0 && br <= 0 && bl <= 0 { return VectorPath([.polygon([(x, y), (x + w, y), (x + w, y + h), (x, y + h)])]) }
        let x1 = x + w, y1 = y + h, k = kappa
        var knots: [Knot] = []
        func arc(_ s: (Double, Double), _ e: (Double, Double), _ cs: (Double, Double), _ ce: (Double, Double), _ r: Double) {
            let sp = PCPoint(s.0, s.1), ep = PCPoint(e.0, e.1)
            if r <= 0 { knots.append(Knot(anchor: sp, inCtrl: sp, outCtrl: sp)); return }
            knots.append(Knot(anchor: sp, inCtrl: sp, outCtrl: PCPoint(cs.0, cs.1)))
            knots.append(Knot(anchor: ep, inCtrl: PCPoint(ce.0, ce.1), outCtrl: ep))
        }
        arc((x1 - tr, y), (x1, y + tr), (x1 - tr + k * tr, y), (x1, y + tr - k * tr), tr)
        arc((x1, y1 - br), (x1 - br, y1), (x1, y1 - br + k * br), (x1 - br + k * br, y1), br)
        arc((x + bl, y1), (x, y1 - bl), (x + bl - k * bl, y1), (x, y1 - bl + k * bl), bl)
        arc((x, y + tl), (x + tl, y), (x, y + tl - k * tl), (x + tl - k * tl, y), tl)
        // Start at the top-left arc's end so the first knot is on the top edge.
        knots = [knots.last!] + knots.dropLast()
        var out: [Knot] = []
        for kn in knots {
            if let last = out.last, abs(last.anchor.x - kn.anchor.x) < 1e-12, abs(last.anchor.y - kn.anchor.y) < 1e-12 {
                out[out.count - 1].outCtrl = kn.outCtrl
                continue
            }
            out.append(kn)
        }
        if out.count > 1, abs(out[0].anchor.x - out.last!.anchor.x) < 1e-12, abs(out[0].anchor.y - out.last!.anchor.y) < 1e-12 {
            out[0].inCtrl = out.last!.inCtrl
            out.removeLast()
        }
        return VectorPath([Subpath(closed: true, knots: out)])
    }

    static func ellipse(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> VectorPath {
        let rx = w / 2, ry = h / 2, cx = x + rx, cy = y + ry, kx = rx * kappa, ky = ry * kappa
        func s(_ a: (Double, Double), _ i: (Double, Double), _ o: (Double, Double)) -> Knot {
            Knot.smooth(anchor: PCPoint(a.0, a.1), inCtrl: PCPoint(i.0, i.1), outCtrl: PCPoint(o.0, o.1))
        }
        return VectorPath([Subpath(closed: true, knots: [
            s((cx, cy - ry), (cx - kx, cy - ry), (cx + kx, cy - ry)),
            s((cx + rx, cy), (cx + rx, cy - ky), (cx + rx, cy + ky)),
            s((cx, cy + ry), (cx + kx, cy + ry), (cx - kx, cy + ry)),
            s((cx - rx, cy), (cx - rx, cy + ky), (cx - rx, cy - ky)),
        ])])
    }

    static func polygon(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ sides: Int, _ starRatio: Double) -> VectorPath {
        let n = min(max(sides, 3), 100)
        let rx = w / 2, ry = h / 2, cx = x + rx, cy = y + ry
        let star = starRatio > 0 && starRatio < 1
        let count = star ? n * 2 : n
        let pts = (0..<count).map { i -> (Double, Double) in
            let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(count)
            let kk = star && i % 2 == 1 ? starRatio : 1
            return (cx + rx * kk * cos(a), cy + ry * kk * sin(a))
        }
        return VectorPath([.polygon(pts)])
    }

    static func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ weight: Double) -> VectorPath {
        let d = b - a, l = (d * d).sum().squareRoot(), hw = max(weight, 0) / 2
        let (nx, ny) = l > 0 ? (-d.y / l * hw, d.x / l * hw) : (0, hw)
        return VectorPath([.polygon([(a.x + nx, a.y + ny), (b.x + nx, b.y + ny), (b.x - nx, b.y - ny), (a.x - nx, a.y - ny)])])
    }
}
