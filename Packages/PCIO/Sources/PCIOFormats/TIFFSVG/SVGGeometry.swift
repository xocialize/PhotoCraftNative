// SVG geometry for the import: transforms, path data, the basic shapes, arcs as cubics, viewBox
// mapping, and paths as Bézier knots.
// Port of photocraft-io (crates/io/src/svg.rs: `knots`) plus the parts of usvg it relies on
// (shapes as paths, arcs as cubics via kurbo with a 0.1 tolerance), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import PCDocument

extension SVGImport {
    // MARK: - Transforms

    /// `transform` attribute (`matrix`, `translate`, `scale`, `rotate`, `skewX`, `skewY`), as
    /// one matrix; an unparsable list is the identity from the bad item on (as browsers do).
    static func parseTransform(_ s: String?) -> CGAffineTransform {
        guard let s, !s.isEmpty else { return .identity }
        var t = CGAffineTransform.identity
        var sc = NumberScanner(Array(s.utf8))
        while true {
            sc.skipSeparators()
            guard !sc.atEnd else { break }
            var name = ""
            while let c = sc.peek(), (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) {
                name.append(Character(Unicode.Scalar(c)))
                sc.i += 1
            }
            sc.skipWhitespace()
            guard sc.peek() == 0x28 else { break }
            sc.i += 1
            var args: [Double] = []
            while let v = sc.number() { args.append(v) }
            sc.skipSeparators()
            guard sc.peek() == 0x29 else { break }
            sc.i += 1
            let m: CGAffineTransform
            switch (name, args.count) {
            case ("matrix", 6): m = CGAffineTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            case ("translate", 1): m = CGAffineTransform(translationX: args[0], y: 0)
            case ("translate", 2): m = CGAffineTransform(translationX: args[0], y: args[1])
            case ("scale", 1): m = CGAffineTransform(scaleX: args[0], y: args[0])
            case ("scale", 2): m = CGAffineTransform(scaleX: args[0], y: args[1])
            case ("rotate", 1): m = CGAffineTransform(rotationAngle: args[0] * .pi / 180)
            case ("rotate", 3):
                m = CGAffineTransform(translationX: args[1], y: args[2]).rotated(by: args[0] * .pi / 180).translatedBy(x: -args[1], y: -args[2])
            case ("skewX", 1): m = CGAffineTransform(a: 1, b: 0, c: tan(args[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case ("skewY", 1): m = CGAffineTransform(a: 1, b: tan(args[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: return t
            }
            // `transform="A B"` maps a point by B first, then A.
            t = m.concatenating(t)
        }
        return t
    }

    /// `outer ∘ inner`: points go through `inner` first.
    static func then(_ inner: CGAffineTransform, _ outer: CGAffineTransform) -> CGAffineTransform { inner.concatenating(outer) }

    static func isFinite(_ t: CGAffineTransform) -> Bool {
        [t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy(\.isFinite)
    }

    /// The `viewBox` → viewport mapping for `preserveAspectRatio` (default `xMidYMid meet`).
    static func viewBoxTransform(_ vb: CGRect, _ par: String?, width: Double, height: Double) -> CGAffineTransform {
        guard vb.width > 0, vb.height > 0, width > 0, height > 0 else { return .identity }
        let words = (par ?? "").split(separator: " ").map { $0.lowercased() }
        let align = words.first { $0 != "defer" } ?? "xmidymid"
        let slice = words.contains("slice")
        var sx = width / vb.width, sy = height / vb.height
        if align != "none" {
            let s = slice ? max(sx, sy) : min(sx, sy)
            sx = s
            sy = s
        }
        var tx = -vb.minX * sx, ty = -vb.minY * sy
        if align != "none" {
            let dw = width - vb.width * sx, dh = height - vb.height * sy
            if align.contains("xmid") { tx += dw / 2 } else if align.contains("xmax") { tx += dw }
            if align.contains("ymid") { ty += dh / 2 } else if align.contains("ymax") { ty += dh }
        }
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
    }

    /// `viewBox="x y w h"`, when valid.
    static func viewBox(_ s: String?) -> CGRect? {
        let v = numbers(s)
        guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    // MARK: - Paths

    /// Appends an SVG elliptical arc from the current point as cubics (kurbo `Arc::from_svg_arc`
    /// + `to_cubic_beziers(0.1)`, as usvg does); degenerate arcs are lines.
    static func arcTo(_ p: CGMutablePath, _ rx0: Double, _ ry0: Double, _ rotation: Double, _ large: Bool, _ sweep: Bool, _ x: Double, _ y: Double) {
        let from = p.isEmpty ? CGPoint(x: x, y: y) : p.currentPoint
        let to = CGPoint(x: x, y: y)
        var rx = abs(rx0), ry = abs(ry0)
        if from == to { return }
        if rx < 1e-5 || ry < 1e-5 || !rx.isFinite || !ry.isFinite {
            p.addLine(to: to)
            return
        }
        let phi = rotation.truncatingRemainder(dividingBy: 360) * .pi / 180
        let (cosPhi, sinPhi) = (cos(phi), sin(phi))
        let dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            let s = lambda.squareRoot()
            rx *= s
            ry *= s
        }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den > 0 ? (max(0, num) / den).squareRoot() : 0
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry
        let cy1 = -coef * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (from.x + to.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (from.y + to.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let ux = (x1 - cx1) / rx, uy = (y1 - cy1) / ry
        let vx = (-x1 - cx1) / rx, vy = (-y1 - cy1) / ry
        let start = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep, delta > 0 { delta -= 2 * .pi } else if sweep, delta < 0 { delta += 2 * .pi }
        guard start.isFinite, delta.isFinite, cx.isFinite, cy.isFinite else {
            p.addLine(to: to)
            return
        }
        // kurbo: subdivisions from the error tolerance.
        let tolerance = 0.1
        let scaledErr = max(rx, ry) / tolerance
        let nErr = max(pow(1.1163 * scaledErr, 1.0 / 6.0), 3.999_999)
        let n = max(1, Int((nErr * abs(delta) / (2 * .pi)).rounded(.up)))
        let step = delta / Double(n)
        let arm = 4.0 / 3.0 * abs(tan(step / 4)) * (step < 0 ? -1 : 1)
        func point(_ a: Double) -> CGPoint {
            let (ca, sa) = (cos(a), sin(a))
            return CGPoint(x: cx + rx * ca * cosPhi - ry * sa * sinPhi, y: cy + rx * ca * sinPhi + ry * sa * cosPhi)
        }
        func derivative(_ a: Double) -> CGPoint {
            let (ca, sa) = (cos(a), sin(a))
            return CGPoint(x: -rx * sa * cosPhi - ry * ca * sinPhi, y: -rx * sa * sinPhi + ry * ca * cosPhi)
        }
        var a0 = start
        var p0 = from
        for k in 0 ..< n {
            let a1 = start + step * Double(k + 1)
            let p1 = k == n - 1 ? to : point(a1)
            let d0 = derivative(a0), d1 = derivative(a1)
            p.addCurve(to: p1, control1: CGPoint(x: p0.x + arm * d0.x, y: p0.y + arm * d0.y),
                       control2: CGPoint(x: p1.x - arm * d1.x, y: p1.y - arm * d1.y))
            a0 = a1
            p0 = p1
        }
    }

    /// Parses path data (`d`). Rendering stops at the first error, as SVG requires.
    static func parsePathData(_ d: String?) -> CGMutablePath {
        let p = CGMutablePath()
        guard let d else { return p }
        var sc = NumberScanner(Array(d.utf8))
        var cmd: UInt8 = 0
        var start = CGPoint.zero
        var last = CGPoint.zero
        var lastCubicCtrl: CGPoint?
        var lastQuadCtrl: CGPoint?
        // A drawing command after `z` (or first) starts a subpath at the current point.
        var needMove = true
        func isCommand(_ c: UInt8) -> Bool { "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c) }
        loop: while true {
            sc.skipSeparators()
            guard let c = sc.peek() else { break }
            if isCommand(c) {
                cmd = c
                sc.i += 1
            } else if cmd == 0 || cmd == 0x5A || cmd == 0x7A {
                break // numbers without a command
            }
            // Path data must begin with a moveto.
            if p.isEmpty, cmd | 0x20 != 0x6D { break }
            let rel = cmd >= 0x61
            let base = rel ? last : .zero
            func pt() -> CGPoint? {
                guard let x = sc.number(), let y = sc.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            switch cmd | 0x20 {
            case 0x6D: // m
                guard let q = pt() else { break loop }
                p.move(to: q)
                needMove = false
                start = q
                last = q
                // Further pairs are implicit line-tos.
                cmd = rel ? 0x6C : 0x4C
                lastCubicCtrl = nil
                lastQuadCtrl = nil
                continue loop
            case 0x6C: // l
                guard let q = pt() else { break loop }
                if needMove { p.move(to: last); needMove = false }
                p.addLine(to: q)
                last = q
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case 0x68: // h
                guard let x = sc.number() else { break loop }
                let q = CGPoint(x: (rel ? last.x : 0) + x, y: last.y)
                if needMove { p.move(to: last); needMove = false }
                p.addLine(to: q)
                last = q
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case 0x76: // v
                guard let y = sc.number() else { break loop }
                let q = CGPoint(x: last.x, y: (rel ? last.y : 0) + y)
                if needMove { p.move(to: last); needMove = false }
                p.addLine(to: q)
                last = q
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case 0x63: // c
                guard let c1 = pt(), let c2 = pt(), let q = pt() else { break loop }
                if needMove { p.move(to: last); needMove = false }
                p.addCurve(to: q, control1: c1, control2: c2)
                last = q
                lastCubicCtrl = c2
                lastQuadCtrl = nil
            case 0x73: // s
                guard let c2 = pt(), let q = pt() else { break loop }
                let c1 = lastCubicCtrl.map { CGPoint(x: 2 * last.x - $0.x, y: 2 * last.y - $0.y) } ?? last
                if needMove { p.move(to: last); needMove = false }
                p.addCurve(to: q, control1: c1, control2: c2)
                last = q
                lastCubicCtrl = c2
                lastQuadCtrl = nil
            case 0x71: // q
                guard let c1 = pt(), let q = pt() else { break loop }
                if needMove { p.move(to: last); needMove = false }
                p.addQuadCurve(to: q, control: c1)
                last = q
                lastQuadCtrl = c1
                lastCubicCtrl = nil
            case 0x74: // t
                guard let q = pt() else { break loop }
                let c1 = lastQuadCtrl.map { CGPoint(x: 2 * last.x - $0.x, y: 2 * last.y - $0.y) } ?? last
                if needMove { p.move(to: last); needMove = false }
                p.addQuadCurve(to: q, control: c1)
                last = q
                lastQuadCtrl = c1
                lastCubicCtrl = nil
            case 0x61: // a
                guard let rx = sc.number(), let ry = sc.number(), let rot = sc.number(), let large = sc.flag(), let sweep = sc.flag(),
                      let x = sc.number(), let y = sc.number() else { break loop }
                let q = CGPoint(x: base.x + x, y: base.y + y)
                if needMove { p.move(to: last); needMove = false }
                arcTo(p, rx, ry, rot, large, sweep, q.x, q.y)
                last = q
                lastCubicCtrl = nil
                lastQuadCtrl = nil
            case 0x7A: // z
                if !p.isEmpty, !needMove { p.closeSubpath() }
                needMove = true
                last = start
                lastCubicCtrl = nil
                lastQuadCtrl = nil
                // A command must follow.
                sc.skipSeparators()
                if let n = sc.peek(), !isCommand(n) { break loop }
                continue loop
            default:
                break loop
            }
        }
        return p
    }

    /// The geometry of a basic shape element in user units (usvg's shape → path conversion).
    /// `nil` for non-shapes and shapes that draw nothing.
    static func shapePath(_ n: Node, viewport: CGSize, fontSize: Double) -> CGMutablePath? {
        func len(_ k: String, _ base: Double, _ def: Double = 0) -> Double {
            length(n.attrs[k], percentBase: base, fontSize: fontSize) ?? def
        }
        let w = viewport.width, h = viewport.height
        let diag = ((w * w + h * h) / 2).squareRoot()
        let p = CGMutablePath()
        switch n.name {
        case "path":
            let q = parsePathData(n.attrs["d"])
            return q.isEmpty ? nil : q
        case "rect":
            let x = len("x", w), y = len("y", h), rw = len("width", w), rh = len("height", h)
            guard rw > 0, rh > 0 else { return nil }
            var rx = length(n.attrs["rx"], percentBase: w, fontSize: fontSize)
            var ry = length(n.attrs["ry"], percentBase: h, fontSize: fontSize)
            if let v = rx, v < 0 { rx = nil }
            if let v = ry, v < 0 { ry = nil }
            var (cx, cy) = (rx ?? ry ?? 0, ry ?? rx ?? 0)
            cx = min(cx, rw / 2)
            cy = min(cy, rh / 2)
            if cx <= 0 || cy <= 0 {
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x + rw, y: y))
                p.addLine(to: CGPoint(x: x + rw, y: y + rh))
                p.addLine(to: CGPoint(x: x, y: y + rh))
                p.closeSubpath()
            } else {
                p.move(to: CGPoint(x: x + cx, y: y))
                p.addLine(to: CGPoint(x: x + rw - cx, y: y))
                arcTo(p, cx, cy, 0, false, true, x + rw, y + cy)
                p.addLine(to: CGPoint(x: x + rw, y: y + rh - cy))
                arcTo(p, cx, cy, 0, false, true, x + rw - cx, y + rh)
                p.addLine(to: CGPoint(x: x + cx, y: y + rh))
                arcTo(p, cx, cy, 0, false, true, x, y + rh - cy)
                p.addLine(to: CGPoint(x: x, y: y + cy))
                arcTo(p, cx, cy, 0, false, true, x + cx, y)
                p.closeSubpath()
            }
        case "circle", "ellipse":
            let cx = len("cx", w), cy = len("cy", h)
            let rx: Double, ry: Double
            if n.name == "circle" {
                rx = len("r", diag)
                ry = rx
            } else {
                let ax = length(n.attrs["rx"], percentBase: w, fontSize: fontSize)
                let ay = length(n.attrs["ry"], percentBase: h, fontSize: fontSize)
                rx = ax ?? ay ?? 0
                ry = ay ?? ax ?? 0
            }
            guard rx > 0, ry > 0 else { return nil }
            p.move(to: CGPoint(x: cx + rx, y: cy))
            arcTo(p, rx, ry, 0, false, true, cx, cy + ry)
            arcTo(p, rx, ry, 0, false, true, cx - rx, cy)
            arcTo(p, rx, ry, 0, false, true, cx, cy - ry)
            arcTo(p, rx, ry, 0, false, true, cx + rx, cy)
            p.closeSubpath()
        case "line":
            p.move(to: CGPoint(x: len("x1", w), y: len("y1", h)))
            p.addLine(to: CGPoint(x: len("x2", w), y: len("y2", h)))
        case "polyline", "polygon":
            let v = numbers(n.attrs["points"])
            guard v.count >= 4 else { return nil }
            p.move(to: CGPoint(x: v[0], y: v[1]))
            var i = 2
            while i + 1 < v.count {
                p.addLine(to: CGPoint(x: v[i], y: v[i + 1]))
                i += 2
            }
            if n.name == "polygon" { p.closeSubpath() }
        default:
            return nil
        }
        return p
    }

    // MARK: - Knots

    /// A flattened-transform path as subpaths of knots (photocraft `knots`): lines keep retracted
    /// handles, quadratics are raised to cubics, and a closing segment that returns to the start
    /// merges into it. Every subpath after the first joins its component, so the fill rule counts
    /// winding across the whole path as SVG does (a second subpath drawn inside the first is a
    /// hole under even-odd).
    static func knots(_ path: CGPath) -> [Subpath] {
        var out: [Subpath] = []
        var cur: Subpath?
        func flush(_ closed: Bool) {
            guard var sp = cur else { return }
            cur = nil
            sp.closed = closed
            if closed, sp.knots.count > 1, let first = sp.knots.first, let last = sp.knots.last,
               abs(first.anchor.x - last.anchor.x) < 1e-6, abs(first.anchor.y - last.anchor.y) < 1e-6 {
                sp.knots.removeLast()
                sp.knots[0].inCtrl = last.inCtrl
            }
            if !sp.knots.isEmpty {
                if !out.isEmpty { sp.op = .join }
                out.append(sp)
            }
        }
        func curve(_ c1: PCPoint, _ c2: PCPoint, _ p: PCPoint) {
            guard var sp = cur, !sp.knots.isEmpty else { return }
            sp.knots[sp.knots.count - 1].outCtrl = c1
            sp.knots.append(Knot(anchor: p, inCtrl: c2, outCtrl: p, smooth: false))
            cur = sp
        }
        func pt(_ p: CGPoint) -> PCPoint { PCPoint(Double(p.x), Double(p.y)) }
        path.applyWithBlock { e in
            let el = e.pointee
            switch el.type {
            case .moveToPoint:
                flush(false)
                let p = el.points[0]
                cur = Subpath(closed: false, knots: [Knot.corner(Double(p.x), Double(p.y))], op: .combine)
            case .addLineToPoint:
                let p = el.points[0]
                cur?.knots.append(Knot.corner(Double(p.x), Double(p.y)))
            case .addQuadCurveToPoint:
                guard let p0 = cur?.knots.last?.anchor else { return }
                let c = pt(el.points[0]), p = pt(el.points[1])
                let c1 = PCPoint(p0.x + 2.0 / 3.0 * (c.x - p0.x), p0.y + 2.0 / 3.0 * (c.y - p0.y))
                let c2 = PCPoint(p.x + 2.0 / 3.0 * (c.x - p.x), p.y + 2.0 / 3.0 * (c.y - p.y))
                curve(c1, c2, p)
            case .addCurveToPoint:
                curve(pt(el.points[0]), pt(el.points[1]), pt(el.points[2]))
            case .closeSubpath:
                flush(true)
            @unknown default:
                break
            }
        }
        flush(false)
        return out
    }
}
