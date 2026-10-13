// Port of photocraft-affinity (crates/affinity/src/shapes.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Parametric shapes: Affinity stores the shape's parameters and its box, never the outline. Formulas
// were fitted by photocraft to Affinity's own renders (the document thumbnails) of public files.

import Darwin

extension Affinity {
    enum Shapes {
        /// Handle length of a quarter circle of radius 1.
        static let kappa = 0.552_284_749_830_793_4
        /// Vertices of a polygon or star.
        static let maxSides = 10_000.0
        static let tau = 2 * Double.pi
        static let halfPi = Double.pi / 2

        /// The last value of a tag: a shape changed from one kind to another keeps a stale first block.
        static func last(_ r: Reader, _ id: ObjID, _ tag: Tag) -> Value? {
            r.s.object(id)?.fields.last { $0.tag == tag }?.value
        }

        static func num(_ r: Reader, _ id: ObjID, _ tag: Tag) -> Double? {
            switch last(r, id, tag) {
            case .float(let f)? where f.isFinite: f
            case .uint(let u)?: Double(u)
            case .int(let i)?: Double(i)
            default: nil
            }
        }

        static func sides(_ r: Reader, _ id: ObjID, _ tag: Tag, _ fallback: Double) -> Int {
            let n = (num(r, id, tag) ?? fallback).rounded()
            return Affinity.saturating(Affinity.clamp(n, 3, maxSides))
        }

        @inline(__always) static func pt(_ x: Double, _ y: Double) -> Point {
            Point(x: x, y: y)
        }

        @inline(__always) static func line(_ p: Point) -> Segment {
            Segment(p, p, p)
        }

        static func polygon(_ pts: [Point]) -> SubPath? {
            guard let start = pts.first else { return nil }
            return SubPath(start: start, segments: pts.dropFirst().map(line), closed: true)
        }

        /// Outline of `shape` (a `Shpe` object) in the node box `b` = (x0, y0, x1, y1).
        static func shape(_ r: Reader, _ shape: ObjID, _ b: [Double], _ world: Affine) -> (Path, Bool)? {
            let (x0, y0, x1, y1) = (b[0], b[1], b[2], b[3])
            let (w, h) = (x1 - x0, y1 - y0)
            let (cx, cy, rx, ry) = ((x0 + x1) / 2, (y0 + y1) / 2, w / 2, h / 2)
            func onEllipse(_ a: Double, _ f: Double) -> Point {
                pt(cx + f * rx * cos(a), cy + f * ry * sin(a))
            }
            guard let cls = r.s.classTag(shape) else { return nil }
            let sub: SubPath
            switch cls {
            case "ShNR", "ShRR":
                var rounded = false
                if case .array(let a)? = last(r, shape, "CTyp"), !a.isEmpty { rounded = true }
                var radius: Double?
                if case .floats(let v)? = last(r, shape, "ShCR"), let f = v.first, f.isFinite, f > 0 { radius = f }
                if rounded, let f = radius {
                    if case .array(let types)? = last(r, shape, "CTyp"),
                       types.contains(where: { if case .enumeration(id: 0, _) = $0 { false } else if case .enumeration(id: 4, _) = $0 { false } else { true } }) {
                        r.warn("rectangles with straight, concave or other corner types (imported with round corners)")
                    }
                    let crx: Double
                    let cry: Double
                    if r.s.bool(shape, "AbSz") == true {
                        // An absolute radius is in document pixels, whatever the node's scale.
                        let sx = (world.a * world.a + world.b * world.b).squareRoot()
                        let sy = (world.c * world.c + world.d * world.d).squareRoot()
                        (crx, cry) = sx > 0 && sy > 0 ? (f / sx, f / sy) : (0, 0)
                    } else {
                        let m = f * Double.minimum(w, h)
                        (crx, cry) = (m, m)
                    }
                    sub = roundedRect(b, Double.minimum(crx, w / 2), Double.minimum(cry, h / 2))
                } else {
                    guard let p = polygon([pt(x0, y0), pt(x1, y0), pt(x1, y1), pt(x0, y1)]) else { return nil }
                    sub = p
                }
            case "ShpE":
                sub = ellipse(cx, cy, rx, ry)
            case "ShPy":
                let n = sides(r, shape, "Side", 5)
                func a(_ i: Int) -> Double { -halfPi + tau * Double(i) / Double(n) }
                if case .bool(true)? = last(r, shape, "Smth") {
                    // Smoothed: tangent handles of length curv·4/3·tan(π/2n) along the inscribed ellipse.
                    let k = (num(r, shape, "Curv") ?? 0) * 4 / 3 * tan(Double.pi / (2 * Double(n)))
                    func v(_ i: Int) -> Point { onEllipse(a(i), 1) }
                    func t(_ i: Int) -> Point { pt(-rx * sin(a(i)), ry * cos(a(i))) }
                    let segments = (0..<n).map { i -> Segment in
                        let (p, q, tp, tq) = (v(i), v(i + 1), t(i), t(i + 1))
                        return Segment(pt(p.x + k * tp.x, p.y + k * tp.y), pt(q.x - k * tq.x, q.y - k * tq.y), q)
                    }
                    sub = SubPath(start: v(0), segments: segments, closed: true)
                } else {
                    guard let p = polygon((0..<n).map { onEllipse(a($0), 1) }) else { return nil }
                    sub = p
                }
            case "ShSt":
                let n = sides(r, shape, "Pnts", 5)
                let q = Affinity.clamp(num(r, shape, "IRad") ?? 0.382, 0, 1)
                if ["CrcI", "CrcO", "CrvL", "CrvR"].contains(where: { t in num(r, shape, Tag(t)).map { abs($0) > 1e-9 } ?? false }) {
                    r.warn("stars with rounded or curved points (imported with sharp points)")
                }
                guard let p = polygon((0..<(2 * n)).map { i in onEllipse(-halfPi + Double.pi * Double(i) / Double(n), i % 2 == 0 ? 1 : q) }) else { return nil }
                sub = p
            case "ShSS":
                let n = sides(r, shape, "Side", 5)
                let ri = Affinity.clamp(num(r, shape, "COut") ?? 0.5, 0, 1)
                let step = Double.pi / Double(n)
                let (l, hw, inner) = (cos(step), ri * sin(step), ri * cos(step))
                let pts = (0..<n).flatMap { k -> [Point] in
                    let phi = -halfPi + step + tau * Double(k) / Double(n)
                    let (c, s) = (cos(phi), sin(phi))
                    return [(inner, -hw), (l, -hw), (l, hw), (inner, hw)].map { u, v in pt(cx + rx * (u * c - v * s), cy + ry * (u * s + v * c)) }
                }
                guard let p = polygon(pts) else { return nil }
                sub = p
            case "ShPi":
                let start = num(r, shape, "AngS") ?? 0
                var end = num(r, shape, "AngE") ?? tau
                end = unwrap(end, above: start)
                let inner = Affinity.clamp(num(r, shape, "IRad") ?? 0, 0, 1)
                sub = pie(cx, cy, rx, ry, start, Double.minimum(end, start + tau), inner)
            case "ShpT":
                let p = num(r, shape, "Pos ") ?? 0.5
                guard let t = polygon([pt(x0 + p * w, y0), pt(x1, y1), pt(x0, y1)]) else { return nil }
                sub = t
            case "ShTz":
                let (l, rr) = (num(r, shape, "PosL") ?? 0.25, num(r, shape, "PosR") ?? 0.75)
                guard let t = polygon([pt(x0 + l * w, y0), pt(x0 + rr * w, y0), pt(x1, y1), pt(x0, y1)]) else { return nil }
                sub = t
            case "ShCl":
                sub = cloud(cx, cy, rx, ry, sides(r, shape, "Bubl", 12))
            case "ShHt":
                sub = heart(b)
            case "ShCg":
                sub = cog(r, shape, cx, cy, rx, ry)
            case "ShCR":
                sub = calloutRect(r, shape, b)
            case "ShCE":
                sub = calloutEllipse(r, shape, cx, cy, rx, ry)
            case "ShDA":
                sub = arrow(r, shape, b)
            case "ShDS":
                sub = doubleStar(r, shape, cx, cy, rx, ry)
            case "ShTr":
                sub = tear(r, shape, b)
            case "ShCr":
                sub = crescent(cx, cy, rx, ry)
            case "ShpD":
                guard let p = polygon([pt(cx, y0), pt(x1, cy), pt(cx, y1), pt(x0, cy)]) else { return nil }
                sub = p
            case "ShSg":
                sub = segment(r, shape, cx, cy, rx, ry)
            default:
                r.warn("an unrecognized parametric shape (imported as its bounding ellipse)")
                sub = ellipse(cx, cy, rx, ry)
            }
            var path = Path(subpaths: [sub])
            if cls == "ShCg" {
                let hole = Affinity.clamp(num(r, shape, "Hole") ?? 0.3, 0, 0.9)
                if hole > 0 { path.subpaths.append(ellipse(cx, cy, rx * hole, ry * hole)) }
                return (path, true)
            }
            return (path, false)
        }

        /// photocraft's `while end < start { end += TAU }`. The angles are finite but file-supplied, so a
        /// far-apart pair would loop for ages (or forever, once adding a turn no longer changes `end`):
        /// after as many turns as a real file could need, the rest is added in one step.
        static func unwrap(_ value: Double, above start: Double) -> Double {
            var end = value
            var turns = 0
            while end < start, turns < 64 {
                end += tau
                turns += 1
            }
            if end < start {
                end += ((start - end) / tau).rounded(.up) * tau
                if end < start { end = start }
            }
            return end
        }

        static func cloud(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ bubbles: Int) -> SubPath {
            let n = min(max(bubbles, 3), 128) * 4
            let points = (0..<n).map { i -> Point in
                let a = tau * Double(i) / Double(n) - halfPi
                let l = 0.5 - 0.5 * cos(tau * Double(i) / 4)
                let radius = 0.78 + 0.22 * (l * l)
                return pt(cx + rx * radius * cos(a), cy + ry * radius * sin(a))
            }
            let segments = (0..<n).map { i -> Segment in
                let p0 = points[(i + n - 1) % n]
                let p1 = points[i]
                let p2 = points[(i + 1) % n]
                let p3 = points[(i + 2) % n]
                return Segment(pt(p1.x + (p2.x - p0.x) / 6, p1.y + (p2.y - p0.y) / 6), pt(p2.x - (p3.x - p1.x) / 6, p2.y - (p3.y - p1.y) / 6), p2)
            }
            return SubPath(start: points[0], segments: segments, closed: true)
        }

        static func heart(_ b: [Double]) -> SubPath {
            let (x0, y0, x1, y1) = (b[0], b[1], b[2], b[3])
            let (w, h) = (x1 - x0, y1 - y0)
            func p(_ x: Double, _ y: Double) -> Point { pt(x0 + x * w, y0 + y * h) }
            let start = p(0.5, 0.92)
            return SubPath(start: start, segments: [
                Segment(p(0.38, 0.85), p(0.04, 0.67), p(0.04, 0.37)),
                Segment(p(0.04, 0.02), p(0.39, 0.00), p(0.5, 0.27)),
                Segment(p(0.61, 0.00), p(0.96, 0.02), p(0.96, 0.37)),
                Segment(p(0.96, 0.67), p(0.62, 0.85), start),
            ], closed: true)
        }

        static func cog(_ r: Reader, _ shape: ObjID, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> SubPath {
            let teeth = sides(r, shape, "Teth", 12)
            let tooth = Affinity.clamp(num(r, shape, "TtSz") ?? 0.3, 0.05, 0.9)
            let notch = Affinity.clamp(num(r, shape, "NtSz") ?? 0.45, 0.05, 0.95)
            let tip = 1.0
            let root = Affinity.clamp(1 - 0.2 * tooth - 0.08 * notch, 0.55, 0.95)
            var pts: [Point] = []
            pts.reserveCapacity(teeth * 4)
            for i in 0..<teeth {
                let base = tau * Double(i) / Double(teeth) - halfPi
                for (offset, radius) in [(-0.5, root), (-0.32, tip), (0.32, tip), (0.5, root)] {
                    let a = base + offset * tau / Double(teeth)
                    pts.append(pt(cx + rx * radius * cos(a), cy + ry * radius * sin(a)))
                }
            }
            return polygon(pts) ?? rectangle(cx - rx, cy - ry, cx + rx, cy + ry)
        }

        static func calloutRect(_ r: Reader, _ shape: ObjID, _ b: [Double]) -> SubPath {
            let (x0, y0, x1, y1) = (b[0], b[1], b[2], b[3])
            let (w, h) = (x1 - x0, y1 - y0)
            let tailH = Affinity.clamp(num(r, shape, "TlHg") ?? 0.2, 0, 0.8) * h
            let tailW = Affinity.clamp(num(r, shape, "TlWd") ?? 0.1, 0.02, 0.8) * w
            let tipX = x0 + Affinity.clamp(num(r, shape, "TlRP") ?? 0.5, 0, 1) * w
            let baseX = x0 + Affinity.clamp(num(r, shape, "TlEP") ?? 0.4, 0, 1) * w
            let a = Affinity.clamp(baseX - tailW / 2, x0, x1)
            let c = Affinity.clamp(baseX + tailW / 2, x0, x1)
            let bodyBottom = y1 - tailH
            let radius = Double.maximum(Double.minimum(w, bodyBottom - y0) * 0.12, 0)
            // The three contours overlap inside the fill; no internal edge is visible in a filled shape.
            // Join the tail to the rounded body in one closed outline to avoid a seam in stroked shapes.
            let start = pt(x0 + radius, y0)
            return SubPath(start: start, segments: [
                line(pt(x1 - radius, y0)),
                Segment(pt(x1 - (1 - kappa) * radius, y0), pt(x1, y0 + (1 - kappa) * radius), pt(x1, y0 + radius)),
                line(pt(x1, bodyBottom - radius)),
                Segment(pt(x1, bodyBottom), pt(x1, bodyBottom), pt(x1 - radius, bodyBottom)),
                Segment(pt(c + radius * 0.2, bodyBottom), pt(tipX, y1 - tailH * 0.15), pt(tipX, y1)),
                line(pt(tipX, y1)),
                Segment(pt(tipX, y1 - tailH * 0.15), pt(a - radius * 0.2, bodyBottom), pt(a, bodyBottom)),
                Segment(pt(x0 + radius, bodyBottom), pt(x0, bodyBottom), pt(x0, bodyBottom - radius)),
                line(pt(x0, y0 + radius)),
                Segment(pt(x0, y0 + (1 - kappa) * radius), pt(x0 + (1 - kappa) * radius, y0), start),
            ], closed: true)
        }

        static func calloutEllipse(_ r: Reader, _ shape: ObjID, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> SubPath {
            let tailH = Affinity.clamp(num(r, shape, "TlHg") ?? 0.2, 0, 0.8)
            let pos = Affinity.clamp(num(r, shape, "TlEP") ?? 0.25, 0, 1)
            let angle = num(r, shape, "TlAn") ?? 0
            let a0 = pos * tau - angle
            let a1 = a0 + 0.35
            let start = pt(cx + rx * cos(a1), cy + ry * sin(a1))
            let end = pt(cx + rx * cos(a0), cy + ry * sin(a0))
            let tip = pt(cx + rx * cos(a0 + 0.18) * 1.08, cy + ry * sin(a0 + 0.18) * (1 + tailH))
            // A single ellipse-like outline with a short triangular tail at its lower edge.
            var segments: [Segment] = []
            arc(cx, cy, rx, ry, a1, a0 + tau, &segments)
            segments.append(Segment(end, end, tip))
            segments.append(Segment(tip, tip, start))
            return SubPath(start: start, segments: segments, closed: true)
        }

        static func arrow(_ r: Reader, _ shape: ObjID, _ b: [Double]) -> SubPath {
            let (x0, y0, x1, y1) = (b[0], b[1], b[2], b[3])
            let h = y1 - y0
            let thick = Affinity.clamp(num(r, shape, "Thck") ?? 0.35, 0.05, 0.9) * h
            let shaft = (y0 + y1 - thick) / 2
            let lower = shaft + thick
            let headStart = x1 - h * 0.45
            return polygon([pt(x0, shaft), pt(headStart, shaft), pt(headStart, y0), pt(x1, (y0 + y1) / 2), pt(headStart, y1), pt(headStart, lower), pt(x0, lower)])
                ?? rectangle(x0, shaft, x1, lower)
        }

        static func doubleStar(_ r: Reader, _ shape: ObjID, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> SubPath {
            let n = min(max(sides(r, shape, "Pnts", 6) * 2, 8), 64)
            let inner = Affinity.clamp(num(r, shape, "IRad") ?? 0.6, 0.05, 0.95)
            let outer = Affinity.clamp(num(r, shape, "PRad") ?? 0.9, 0.2, 1)
            return polygon((0..<(2 * n)).map { i in
                let a = -halfPi + Double.pi * Double(i) / Double(n)
                let radius = i % 2 == 0 ? outer : outer * inner
                return pt(cx + rx * radius * cos(a), cy + ry * radius * sin(a))
            }) ?? rectangle(cx - rx, cy - ry, cx + rx, cy + ry)
        }

        static func tear(_ r: Reader, _ shape: ObjID, _ b: [Double]) -> SubPath {
            let (x0, y0, x1, y1) = (b[0], b[1], b[2], b[3])
            let (w, h) = (x1 - x0, y1 - y0)
            let bulge = Affinity.clamp(num(r, shape, "Ball") ?? 0.25, 0, 0.5)
            let bend = Affinity.clamp(num(r, shape, "Bend") ?? 0, -0.5, 0.5)
            let top = pt((x0 + x1) / 2, y0)
            let bottom = pt((x0 + x1) / 2 + bend * w * 0.25, y1)
            return SubPath(start: top, segments: [
                Segment(pt(x0 + w * 0.25, y0 + h * 0.42), pt(x0 + w * (0.5 - bulge), y1 - h * 0.03), bottom),
                Segment(pt(x1 - w * (0.5 - bulge), y1 - h * 0.03), pt(x1 - w * 0.25, y0 + h * 0.42), top),
            ], closed: true)
        }

        static func crescent(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> SubPath {
            let start = pt(cx, cy - ry)
            var segments: [Segment] = []
            arc(cx, cy, rx, ry, -halfPi, -3 * halfPi, &segments)
            // The inner arc returns from the lower tip to the upper tip, leaving a crescent open to the right.
            let ix = cx + rx * 0.72
            let irx = rx * 0.86
            let iry = ry * 0.82
            let from = pt(ix, cy + iry)
            segments.append(line(from))
            arc(ix, cy, irx, iry, halfPi, -halfPi, &segments)
            return SubPath(start: start, segments: segments, closed: true)
        }

        static func segment(_ r: Reader, _ shape: ObjID, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> SubPath {
            // Keep hostile but finite angles in a small range before constructing arc controls.
            let angle = Affinity.remEuclid(num(r, shape, "Angl") ?? 0, tau)
            let p0 = Affinity.clamp(num(r, shape, "Pos0") ?? 0.25, 0, 1)
            let p1 = Affinity.clamp(num(r, shape, "Pos1") ?? 0.75, 0, 1)
            let a0 = angle + (p0 - 0.5) * tau
            let a1 = unwrap(angle + (p1 - 0.5) * tau, above: a0)
            var segments: [Segment] = []
            arc(cx, cy, rx, ry, a0, Double.minimum(a1, a0 + tau), &segments)
            let start = pt(cx + rx * cos(a0), cy + ry * sin(a0))
            let end = pt(cx + rx * cos(a1), cy + ry * sin(a1))
            segments.append(Segment(end, end, start))
            return SubPath(start: start, segments: segments, closed: true)
        }

        static func rectangle(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> SubPath {
            SubPath(start: pt(x0, y0), segments: [pt(x1, y0), pt(x1, y1), pt(x0, y1)].map(line), closed: true)
        }

        static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> SubPath {
            let (kx, ky) = (kappa * rx, kappa * ry)
            return SubPath(start: pt(cx + rx, cy), segments: [
                Segment(pt(cx + rx, cy + ky), pt(cx + kx, cy + ry), pt(cx, cy + ry)),
                Segment(pt(cx - kx, cy + ry), pt(cx - rx, cy + ky), pt(cx - rx, cy)),
                Segment(pt(cx - rx, cy - ky), pt(cx - kx, cy - ry), pt(cx, cy - ry)),
                Segment(pt(cx + kx, cy - ry), pt(cx + rx, cy - ky), pt(cx + rx, cy)),
            ], closed: true)
        }

        static func roundedRect(_ b: [Double], _ rx: Double, _ ry: Double) -> SubPath {
            let (x0, y0, x1, y1) = (b[0], b[1], b[2], b[3])
            let (kx, ky) = ((1 - kappa) * rx, (1 - kappa) * ry)
            return SubPath(start: pt(x0 + rx, y0), segments: [
                line(pt(x1 - rx, y0)),
                Segment(pt(x1 - kx, y0), pt(x1, y0 + ky), pt(x1, y0 + ry)),
                line(pt(x1, y1 - ry)),
                Segment(pt(x1, y1 - ky), pt(x1 - kx, y1), pt(x1 - rx, y1)),
                line(pt(x0 + rx, y1)),
                Segment(pt(x0 + kx, y1), pt(x0, y1 - ky), pt(x0, y1 - ry)),
                line(pt(x0, y0 + ry)),
                Segment(pt(x0, y0 + ky), pt(x0 + kx, y0), pt(x0 + rx, y0)),
            ], closed: true)
        }

        /// Elliptical arc from angle `a0` to `a1` (radians, measured y-up as Affinity's pie angles are),
        /// as cubic segments of at most a quarter turn.
        static func arc(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ a0: Double, _ a1: Double, _ out: inout [Segment]) {
            let n: Int = Affinity.saturating(Affinity.clamp((abs(a1 - a0) / halfPi).rounded(.up), 1, 8))
            let step = (a1 - a0) / Double(n)
            let k = 4.0 / 3.0 * tan(step / 4)
            func p(_ a: Double) -> Point { pt(cx + rx * cos(a), cy - ry * sin(a)) }
            func d(_ a: Double) -> Point { pt(-rx * sin(a), -ry * cos(a)) }
            for i in 0..<n {
                let (s, e) = (a0 + step * Double(i), a0 + step * Double(i + 1))
                let (ps, pe, ds, de) = (p(s), p(e), d(s), d(e))
                out.append(Segment(pt(ps.x + k * ds.x, ps.y + k * ds.y), pt(pe.x - k * de.x, pe.y - k * de.y), pe))
            }
        }

        static func pie(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ a0: Double, _ a1: Double, _ inner: Double) -> SubPath {
            let start = pt(cx + rx * cos(a0), cy - ry * sin(a0))
            var segments: [Segment] = []
            arc(cx, cy, rx, ry, a0, a1, &segments)
            if inner > 0 {
                segments.append(line(pt(cx + inner * rx * cos(a1), cy - inner * ry * sin(a1))))
                arc(cx, cy, inner * rx, inner * ry, a1, a0, &segments)
            } else {
                segments.append(line(pt(cx, cy)))
            }
            return SubPath(start: start, segments: segments, closed: true)
        }

        /// A polyline with circular corners of the given radii (Affinity's live corners on curves).
        static func fillet(_ pts: [(Point, Double)], _ closed: Bool) -> SubPath {
            let n = pts.count
            func get(_ i: Int) -> Point? {
                if closed {
                    guard n > 0 else { return nil }
                    return pts[((i % n) + n) % n].0
                }
                return pts.indices.contains(i) ? pts[i].0 : nil
            }
            var corners: [(Point, Point, Point, Point)] = []
            corners.reserveCapacity(n)
            for (i, (p, radius)) in pts.enumerated() {
                guard let a = get(i - 1), let b = get(i + 1) else {
                    corners.append((p, p, p, p))
                    continue
                }
                let (u1, l1) = unit(p, a)
                let (u2, l2) = unit(p, b)
                let cosine = Affinity.clamp(u1.x * u2.x + u1.y * u2.y, -1, 1)
                let phi = acos(cosine)
                if radius <= 0 || phi < 1e-6 || (Double.pi - phi) < 1e-6 {
                    corners.append((p, p, p, p))
                    continue
                }
                let t = Double.minimum(Double.minimum(radius / tan(phi / 2), l1 / 2), l2 / 2)
                let r = t * tan(phi / 2)
                let k = 4.0 / 3.0 * tan((Double.pi - phi) / 4) * r
                let s = pt(p.x + u1.x * t, p.y + u1.y * t)
                let e = pt(p.x + u2.x * t, p.y + u2.y * t)
                corners.append((s, pt(s.x - u1.x * k, s.y - u1.y * k), pt(e.x - u2.x * k, e.y - u2.y * k), e))
            }
            guard let first = corners.first else { return SubPath(start: pt(0, 0), segments: [], closed: closed) }
            var segments: [Segment] = []
            segments.reserveCapacity(2 * n)
            var cur = first.0
            let start = cur
            for (i, (s, c1, c2, e)) in corners.enumerated() {
                if i > 0 { segments.append(Segment(cur, s, s)) }
                if s != e { segments.append(Segment(c1, c2, e)) }
                cur = e
            }
            if closed, cur != start { segments.append(Segment(cur, start, start)) }
            return SubPath(start: start, segments: segments, closed: closed)
        }

        static func unit(_ from: Point, _ to: Point) -> (Point, Double) {
            let (dx, dy) = (to.x - from.x, to.y - from.y)
            let l = (dx * dx + dy * dy).squareRoot()
            return l > 0 ? (pt(dx / l, dy / l), l) : (pt(0, 0), 0)
        }
    }
}
