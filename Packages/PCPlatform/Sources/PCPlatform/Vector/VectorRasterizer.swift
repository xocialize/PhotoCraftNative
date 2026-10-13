// Paths → anti-aliased coverage, strokes, shape layers, boolean path operations, hit testing.
// Replaces photocraft-vector (crates/vector/src/{lib,raster,stroke,flatten,edit}.rs: exact-area
// scanline rasteriser, polygon stroker, dashes, Bézier flattening, point-level hit testing) with
// CoreGraphics: CGContext fills/strokes into a 32-bit float gray bitmap, `CGPath.copy(strokingWith…)`
// / `copy(dashingWith…)` for outlines, and macOS 14's `CGPath.union/intersection/subtracting/
// symmetricDifference` for Photoshop's path operations. Port of its API shape, MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.
//
// Everything renders PCDocument's model directly — `VectorPath`, `ShapeLayer`, `ShapeStroke`,
// `VectorMask`, `LiveShape` — as photocraft-vector renders photocraft-doc's.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation

/// Stroke geometry in pixels (photocraft-vector `StrokeStyle`; the document's `ShapeStroke` keeps
/// dashes in widths and the paint).
public struct StrokeStyle: Sendable, Equatable {
    public var width: Double
    public var cap: LineCap
    public var join: LineJoin
    /// Miter length over line width at which a miter turns into a bevel.
    public var miterLimit: Double
    /// Dash pattern in pixels; empty = solid.
    public var dashes: [Double]
    public var dashOffset: Double
    public var align: StrokeAlign

    public init(width: Double, cap: LineCap = .butt, join: LineJoin = .miter, miterLimit: Double = 100, dashes: [Double] = [],
                dashOffset: Double = 0, align: StrokeAlign = .center) {
        self.width = width; self.cap = cap; self.join = join; self.miterLimit = miterLimit
        self.dashes = dashes; self.dashOffset = dashOffset; self.align = align
    }

    /// The geometry of a document shape stroke: dashes and offset from multiples of the width to
    /// pixels (photocraft `stroke_style`).
    public init(_ s: ShapeStroke) {
        let w = Double(max(s.width, 0))
        self.init(width: w, cap: s.cap, join: s.join, miterLimit: Double(max(s.miterLimit, 1)), dashes: s.dashes.map { Double($0) * w },
                  dashOffset: Double(s.dashOffset) * w, align: s.align)
    }
}

public enum VectorGeometry {
    /// The fill area of a path with Photoshop's path operations folded in, as one CGPath filled
    /// non-zero: each component (with its `join`ed subpaths) is normalised with the path's fill rule,
    /// then combined, subtracted, intersected or excluded in order (photocraft `fill_rasterizer`).
    /// `inverted` is not applied (it needs a canvas).
    public static func fillArea(_ path: VectorPath) -> CGPath {
        var acc: CGPath?
        for (ci, comp) in path.components.enumerated() {
            let shape = path.cgPath(comp).normalized(using: path.fillRule.cgFillRule)
            guard let a = acc else { acc = shape; continue }
            switch ci == 0 ? .combine : path.effectiveOp(comp.lowerBound) {
            case .combine, .join: acc = a.union(shape, using: .winding)
            case .subtract: acc = a.subtracting(shape, using: .winding)
            case .intersect: acc = a.intersection(shape, using: .winding)
            case .exclude: acc = a.symmetricDifference(shape, using: .winding)
            }
        }
        return acc ?? CGMutablePath()
    }

    /// The outline of a centred stroke (dashed when the style has dashes), as a fillable path.
    public static func strokeOutline(_ path: VectorPath, style: StrokeStyle) -> CGPath {
        var p = path.cgPath
        if !style.dashes.isEmpty, style.dashes.reduce(0, +) > 0 {
            p = p.copy(dashingWithPhase: style.dashOffset, lengths: style.dashes.map { CGFloat($0) })
        }
        return p.copy(strokingWithWidth: style.width, lineCap: style.cap.cgLineCap, lineJoin: style.join.cgLineJoin, miterLimit: style.miterLimit)
    }
}

/// Boolean operations on whole paths (Pathfinder / Combine Shapes), each path taken as its fill area.
public enum PathBoolean {
    public static func union(_ a: VectorPath, _ b: VectorPath) -> VectorPath {
        VectorPath(cgPath: VectorGeometry.fillArea(a).union(VectorGeometry.fillArea(b), using: .winding))
    }
    public static func intersection(_ a: VectorPath, _ b: VectorPath) -> VectorPath {
        VectorPath(cgPath: VectorGeometry.fillArea(a).intersection(VectorGeometry.fillArea(b), using: .winding))
    }
    public static func subtracting(_ a: VectorPath, _ b: VectorPath) -> VectorPath {
        VectorPath(cgPath: VectorGeometry.fillArea(a).subtracting(VectorGeometry.fillArea(b), using: .winding))
    }
    public static func symmetricDifference(_ a: VectorPath, _ b: VectorPath) -> VectorPath {
        VectorPath(cgPath: VectorGeometry.fillArea(a).symmetricDifference(VectorGeometry.fillArea(b), using: .winding))
    }
    /// Folds a path's own operations into plain combined geometry (Merge Shape Components).
    public static func merged(_ p: VectorPath) -> VectorPath {
        var out = VectorPath(cgPath: VectorGeometry.fillArea(p))
        out.inverted = p.inverted
        return out
    }
}

public enum VectorRasterizer {
    /// A 32-bit float gray bitmap context over `rect` in document space (y down).
    static func context(_ rect: PixelRect) -> CGContext? {
        let w = max(rect.width, 1), h = max(rect.height, 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.linearGray)!,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -CGFloat(rect.x0), y: -CGFloat(rect.y0))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        return ctx
    }

    static func read(_ ctx: CGContext, _ rect: PixelRect) -> [Float] {
        let n = rect.area
        guard n > 0, let d = ctx.data else { return [] }
        let p = d.assumingMemoryBound(to: Float.self)
        return (0..<n).map { min(max(p[$0], 0), 1) }
    }

    /// Fill coverage (0…1, row-major over `rect`) of a CGPath.
    ///
    /// CoreGraphics computes anti-aliased coverage in 8-bit steps even into a float bitmap
    /// (measured: an exact half-pixel edge reads 127/255). `supersample` > 1 renders at that many
    /// times the resolution and box-filters, giving 1/(255·n²) steps for 16/32-bit masks
    /// (photocraft's rasteriser is exact-area f32).
    public static func coverage(_ path: CGPath, rule: CGPathFillRule = .winding, rect: PixelRect, antialias: Bool = true, supersample: Int = 1) -> [Float] {
        guard !rect.isEmpty else { return [] }
        var path = path
        if reachesFar(path.boundingBox, from: rect) {
            path = fillSafe(VectorPath(cgPath: path, fillRule: rule == .evenOdd ? .evenOdd : .nonZero), near: rect).cgPath
        }
        let n = max(1, supersample)
        if n == 1 {
            guard let ctx = context(rect) else { return [] }
            ctx.setShouldAntialias(antialias)
            ctx.addPath(path)
            ctx.fillPath(using: rule)
            return read(ctx, rect)
        }
        let big = PixelRect(x: Int(rect.x0) * n, y: Int(rect.y0) * n, width: rect.width * n, height: rect.height * n)
        guard let ctx = context(big) else { return [] }
        ctx.setShouldAntialias(antialias)
        ctx.scaleBy(x: CGFloat(n), y: CGFloat(n))
        ctx.addPath(path)
        ctx.fillPath(using: rule)
        let hi = read(ctx, big), w = rect.width, bw = big.width
        var out = [Float](repeating: 0, count: rect.area)
        let inv = 1 / Float(n * n)
        for y in 0..<rect.height { for x in 0..<w {
            var acc: Float = 0
            for sy in 0..<n { for sx in 0..<n { acc += hi[(y * n + sy) * bw + x * n + sx] } }
            out[y * w + x] = acc * inv
        } }
        return out
    }

    /// Fill coverage of a vector path with its operations and inversion (photocraft
    /// `path_coverage`).
    public static func fillCoverage(_ path: VectorPath, rect: PixelRect, antialias: Bool = true, supersample: Int = 1) -> [Float] {
        guard !rect.isEmpty else { return [] }
        var c = coverage(VectorGeometry.fillArea(fillSafe(path, near: rect)), rule: .winding, rect: rect, antialias: antialias, supersample: supersample)
        if path.inverted { for i in c.indices { c[i] = 1 - c[i] } }
        return c
    }

    /// Stroke coverage; inside/outside strokes are a centred stroke twice as wide clipped by the fill
    /// area (photocraft `CompiledShape`).
    public static func strokeCoverage(_ path: VectorPath, style: StrokeStyle, rect: PixelRect, antialias: Bool = true) -> [Float] {
        guard !rect.isEmpty, style.width > 0, let ctx = context(rect) else { return [Float](repeating: 0, count: rect.area) }
        let allClosed = path.subpaths.allSatisfy(\.closed)
        let aligned = allClosed && style.align != .center
        ctx.setShouldAntialias(antialias)
        ctx.setLineWidth(aligned ? style.width * 2 : style.width)
        ctx.setLineCap(style.cap.cgLineCap)
        ctx.setLineJoin(style.join.cgLineJoin)
        ctx.setMiterLimit(style.miterLimit)
        let dashed = !style.dashes.isEmpty && style.dashes.reduce(0, +) > 0
        if reachesFar(path, from: rect) {
            // Pieces cut at a window wider than the stroke reaches, each dashed from its own start.
            let total = style.dashes.reduce(0, +)
            for piece in strokePieces(path, near: rect, margin: strokeReach(style, aligned: aligned)) {
                if dashed { ctx.setLineDash(phase: (style.dashOffset + piece.start).truncatingRemainder(dividingBy: total), lengths: style.dashes.map { CGFloat($0) }) }
                ctx.addPath(piece.path)
                ctx.strokePath()
            }
        } else {
            if dashed { ctx.setLineDash(phase: style.dashOffset, lengths: style.dashes.map { CGFloat($0) }) }
            ctx.addPath(path.cgPath)
            ctx.strokePath()
        }
        var c = read(ctx, rect)
        if aligned {
            let area = coverage(VectorGeometry.fillArea(path), rect: rect, antialias: antialias)
            let inside = style.align == .inside
            for i in c.indices { c[i] *= inside ? area[i] : 1 - area[i] }
        }
        return c
    }

    /// A single-channel coverage surface (selection / mask) at `sample` depth over `clip`, only
    /// tiles with coverage allocated (photocraft `coverage_surface`).
    public static func coverageSurface(_ path: VectorPath, sample: SampleType = .u8, clip: PixelRect, antialias: Bool = true) -> Surface {
        let fmt = PixelFormat(mode: .grayscale, sample: sample, alpha: false)
        var s = Surface(format: fmt)
        let area: PixelRect
        if path.inverted { area = clip } else {
            let b = VectorGeometry.fillArea(fillSafe(path, near: clip)).boundingBoxOfPath
            guard !b.isNull, !b.isEmpty else { return s }
            area = PixelRect(x0: Int32(floor(b.minX)) - 1, y0: Int32(floor(b.minY)) - 1, x1: Int32(ceil(b.maxX)) + 1, y1: Int32(ceil(b.maxY)) + 1).intersect(clip)
        }
        for t in area.tiles {
            let r = t.rect.intersect(area)
            let c = fillCoverage(path, rect: r, antialias: antialias)
            if c.contains(where: { $0 > 0 }) { s.writeRegion(r, c) }
        }
        return s
    }

    /// A vector mask's values over `rect` (photocraft `vector_mask_values` / `CompiledVectorMask`):
    /// all ones when disabled; an enabled mask without subpaths reveals everything (hides everything
    /// when inverted), as Photoshop's fresh "Add Vector Mask"; density applied. `feather` is stored
    /// by the model and not rendered (as in photocraft).
    public static func coverage(of mask: VectorMask, rect: PixelRect, supersample: Int = 1) -> [Float] {
        if !mask.enabled { return [Float](repeating: 1, count: rect.area) }
        var v: [Float] = mask.path.isEmpty ? [Float](repeating: mask.path.inverted ? 0 : 1, count: rect.area)
            : fillCoverage(mask.path, rect: rect, supersample: supersample)
        if mask.density < 1 {
            let d = min(max(mask.density, 0), 1)
            for i in v.indices { v[i] = 1 - d * (1 - v[i]) }
        }
        return v
    }

    /// Pixel bounds a shape layer's rendering can touch (photocraft `CompiledShape::bounds`), nil
    /// when nothing is visible.
    public static func bounds(of shape: ShapeLayer, clip: PixelRect) -> PixelRect? {
        var b = CGRect.null
        let far = reachesFar(shape.path, from: clip)
        if shape.fill != nil { b = shape.path.inverted ? clip.cgRect : VectorGeometry.fillArea(fillSafe(shape.path, near: clip)).boundingBoxOfPath }
        if let st = shape.stroke, st.width > 0, st.opacity > 0 {
            // The outline of the centred stroke (twice as wide for inside/outside alignment).
            var style = StrokeStyle(st)
            if st.align != .center { style.width *= 2 }
            if far {
                let reach = strokeReach(style, aligned: false)
                for piece in strokePieces(shape.path, near: clip, margin: reach) { b = b.union(piece.path.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach)) }
            } else {
                b = b.union(VectorGeometry.strokeOutline(shape.path, style: style).boundingBoxOfPath)
            }
        }
        guard !b.isNull, !b.isEmpty else { return nil }
        let r = PixelRect(x0: Int32(max(floor(b.minX), -1e9)) - 1, y0: Int32(max(floor(b.minY), -1e9)) - 1,
                          x1: Int32(min(ceil(b.maxX), 1e9)) + 1, y1: Int32(min(ceil(b.maxY), 1e9)) + 1).intersect(clip)
        return r.isEmpty ? nil : r
    }

    /// Straight RGBA for every pixel of `rect`: the fill, then the stroke over it with its opacity
    /// (photocraft `CompiledShape::render_rgba`). `canvas` lays out gradients whose fill is not
    /// aligned with the layer.
    public static func rgba(of shape: ShapeLayer, rect: PixelRect, canvas: PixelRect) -> [SIMD4<Float>] {
        let pb = shape.path.controlBounds ?? .zero
        let cb = SIMD4(Double(canvas.x0), Double(canvas.y0), Double(canvas.x1), Double(canvas.y1))
        var out = [SIMD4<Float>](repeating: .zero, count: rect.area)
        let w = rect.width
        if let f = shape.fill {
            let paint = ShapePaint(f, bounds: pb, canvas: cb)
            let cov = fillCoverage(shape.path, rect: rect)
            for i in out.indices where cov[i] > 0 {
                var p = paint.at(Double(rect.x0) + Double(i % w) + 0.5, Double(rect.y0) + Double(i / w) + 0.5)
                p.w *= cov[i]
                out[i] = p
            }
        }
        if let st = shape.stroke, st.width > 0, st.opacity > 0 {
            let paint = ShapePaint(st.paint, bounds: pb, canvas: cb)
            let cov = strokeCoverage(shape.path, style: StrokeStyle(st), rect: rect)
            let opacity = min(max(st.opacity, 0), 1)
            for i in out.indices where cov[i] > 0 {
                let s = paint.at(Double(rect.x0) + Double(i % w) + 0.5, Double(rect.y0) + Double(i / w) + 0.5)
                let sa = s.w * cov[i] * opacity, da = out[i].w
                let a = sa + da * (1 - sa)
                var rgb = SIMD3<Float>(out[i].x, out[i].y, out[i].z)
                if a > 0 { rgb = (SIMD3(s.x, s.y, s.z) * sa + rgb * da * (1 - sa)) / a }
                out[i] = SIMD4(rgb, a)
            }
        }
        return out
    }

    /// Renders a shape layer (fill, then stroke) into a new surface of `format` over `clip` — the
    /// canvas, which also lays out unaligned gradients (photocraft `render_shape`). Only tiles with
    /// visible pixels are allocated.
    public static func rasterize(_ shape: ShapeLayer, format: PixelFormat, clip: PixelRect) -> Surface {
        var s = Surface(format: format)
        guard let area = bounds(of: shape, clip: clip) else { return s }
        let n = format.mode.colorChannels, ch = format.channels
        for t in area.tiles {
            let r = t.rect.intersect(area)
            let px = rgba(of: shape, rect: r, canvas: clip)
            guard px.contains(where: { $0.w > 0 }) else { continue }
            var vals = [Float](repeating: 0, count: r.area * ch)
            for i in px.indices where px[i].w > 0 {
                let c = PCColor(mode: .rgb, c: SIMD4(px[i].x, px[i].y, px[i].z, 0), alpha: px[i].w).converted(to: format.mode)
                for k in 0..<n { vals[i * ch + k] = c.c[k] }
                if format.alpha { vals[i * ch + n] = px[i].w }
            }
            s.writeRegion(r, vals)
        }
        return s
    }

    /// Re-renders `shape.cache` from the model; returns the rectangle drawn.
    @discardableResult
    public static func renderCache(_ shape: inout ShapeLayer, format: PixelFormat, clip: PixelRect) -> PixelRect {
        shape.cache = rasterize(shape, format: format, clip: clip)
        return bounds(of: shape, clip: clip) ?? .empty
    }
}

// MARK: - Far coordinates

extension VectorRasterizer {
    /// How far (px) from the rendered rectangle a path may reach before it is clipped first.
    /// CoreGraphics silently draws nothing once a point is about 1e9 px from the bitmap — measured on
    /// macOS 27.2: a fill or stroke crossing the bitmap is exact with points 5e8 px away and empty at
    /// 1e9, 3e9 and 1e12; the limit is in device space (a small shape 1e12 px away in user space
    /// draws once the CTM brings it near). The margin below it covers supersampling.
    static let farCoordinate = 1e7

    /// Whether any point of `path` is non-finite or farther than `farCoordinate` from `rect`.
    static func reachesFar(_ path: VectorPath, from rect: PixelRect) -> Bool {
        let (x0, y0) = (Double(rect.x0) - farCoordinate, Double(rect.y0) - farCoordinate)
        let (x1, y1) = (Double(rect.x1) + farCoordinate, Double(rect.y1) + farCoordinate)
        return path.subpaths.contains { s in
            s.knots.contains { k in [k.anchor, k.inCtrl, k.outCtrl].contains { !($0.x >= x0 && $0.x <= x1 && $0.y >= y0 && $0.y <= y1) } }
        }
    }

    static func reachesFar(_ bounds: CGRect, from rect: PixelRect) -> Bool {
        if bounds.isNull || bounds.isEmpty { return false }
        let w = rect.cgRect.insetBy(dx: -farCoordinate, dy: -farCoordinate)
        return !(bounds.minX >= w.minX && bounds.maxX <= w.maxX && bounds.minY >= w.minY && bounds.maxY <= w.maxY)
    }

    /// The window clipped geometry is restricted to: `rect` grown by `margin`.
    static func window(_ rect: PixelRect, _ margin: Double) -> CGRect { rect.cgRect.insetBy(dx: -margin, dy: -margin) }

    /// How far a stroke's paint reaches from its path: half its width (all of it when aligned
    /// inside or outside), times the miter limit for miter joins, square caps included.
    static func strokeReach(_ style: StrokeStyle, aligned: Bool) -> Double {
        let half = aligned ? style.width : style.width / 2
        return half * (style.join == .miter ? max(style.miterLimit, 2.squareRoot()) : 2.squareRoot()) + 2
    }

    /// A subpath as a polyline detailed only near `window`: each cubic is flattened (control points
    /// within 0.02 px of the chord's thirds) where its control polygon can touch the window, and
    /// replaced by its chord where it cannot — a curve and its chord then bound only area inside
    /// the control polygon's hull, outside the window, so no winding number inside it changes.
    /// Non-finite points are dropped. `lengths[i]` is the arc length along the original curves at
    /// point `i` (for dash phases).
    static func flatten(_ s: Subpath, window w: CGRect) -> (points: [CGPoint], lengths: [Double]) {
        var pts: [CGPoint] = [], lens: [Double] = []
        func finite(_ p: PCPoint) -> Bool { p.x.isFinite && p.y.isFinite }
        func emit(_ p: CGPoint, _ length: Double) {
            pts.append(p)
            lens.append((lens.last ?? 0) + (length.isFinite ? length : 0))
        }
        func chord(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(b.x - a.x, b.y - a.y)) }
        // Arc length of a cubic: 5-point Gauss–Legendre on its speed.
        func arcLength(_ p: [CGPoint]) -> Double {
            let nodes: [(Double, Double)] = [(0, 0.5688888888888889), (-0.5384693101056831, 0.4786286704993665), (0.5384693101056831, 0.4786286704993665),
                                             (-0.9061798459386640, 0.2369268850561891), (0.9061798459386640, 0.2369268850561891)]
            var sum = 0.0
            for (x, wgt) in nodes {
                let t = (x + 1) / 2, u = 1 - t
                let dx = 3 * (u * u * Double(p[1].x - p[0].x) + 2 * u * t * Double(p[2].x - p[1].x) + t * t * Double(p[3].x - p[2].x))
                let dy = 3 * (u * u * Double(p[1].y - p[0].y) + 2 * u * t * Double(p[2].y - p[1].y) + t * t * Double(p[3].y - p[2].y))
                sum += wgt * (dx * dx + dy * dy).squareRoot()
            }
            return sum / 2
        }
        func cubic(_ p: [CGPoint], _ depth: Int) {
            let xs = p.map(\.x), ys = p.map(\.y)
            let touches = xs.max()! >= w.minX && xs.min()! <= w.maxX && ys.max()! >= w.minY && ys.min()! <= w.maxY
            if !touches { emit(p[3], arcLength(p)); return }
            let d1 = hypot(p[1].x - (2 * p[0].x + p[3].x) / 3, p[1].y - (2 * p[0].y + p[3].y) / 3)
            let d2 = hypot(p[2].x - (p[0].x + 2 * p[3].x) / 3, p[2].y - (p[0].y + 2 * p[3].y) / 3)
            if max(d1, d2) <= 0.02 || depth >= 60 { emit(p[3], chord(p[0], p[3])); return }
            func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
            let ab = mid(p[0], p[1]), bc = mid(p[1], p[2]), cd = mid(p[2], p[3])
            let abc = mid(ab, bc), bcd = mid(bc, cd), m = mid(abc, bcd)
            cubic([p[0], ab, abc, m], depth + 1)
            cubic([m, bcd, cd, p[3]], depth + 1)
        }
        guard let first = s.knots.first(where: { finite($0.anchor) }) else { return ([], []) }
        emit(first.anchor.cgPoint, 0)
        for seg in s.segments where seg.allSatisfy(finite) {
            let p = seg.map(\.cgPoint)
            if seg[1] == seg[0] && seg[2] == seg[3] { emit(p[3], chord(pts.last ?? p[0], p[3])) } else { cubic(p, 0) }
        }
        return (pts, lens)
    }

    /// Sutherland–Hodgman: the closed polygon `poly` clipped to `w`.
    static func clipPolygon(_ poly: [CGPoint], to w: CGRect) -> [CGPoint] {
        func clip(_ poly: [CGPoint], _ inside: (CGPoint) -> Bool, _ cross: (CGPoint, CGPoint) -> CGPoint) -> [CGPoint] {
            guard var prev = poly.last else { return [] }
            var out: [CGPoint] = []
            for cur in poly {
                if inside(cur) {
                    if !inside(prev) { out.append(cross(prev, cur)) }
                    out.append(cur)
                } else if inside(prev) {
                    out.append(cross(prev, cur))
                }
                prev = cur
            }
            return out
        }
        func atX(_ x: CGFloat) -> (CGPoint, CGPoint) -> CGPoint { { a, b in CGPoint(x: x, y: a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)) } }
        func atY(_ y: CGFloat) -> (CGPoint, CGPoint) -> CGPoint { { a, b in CGPoint(x: a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y), y: y) } }
        var p = clip(poly, { $0.x >= w.minX }, atX(w.minX))
        p = clip(p, { $0.x <= w.maxX }, atX(w.maxX))
        p = clip(p, { $0.y >= w.minY }, atY(w.minY))
        return clip(p, { $0.y <= w.maxY }, atY(w.maxY))
    }

    /// `path` ready for filling over `rect` (PCEngine's `rasterSafe`, here for every render):
    /// unchanged unless it reaches farther than `farCoordinate`, else every subpath flattened near
    /// the window (`rect` grown by `margin`) and clipped to it as a closed polygon with its
    /// operation — Sutherland–Hodgman keeps every winding number inside the window, so the fill
    /// there is the same.
    static func fillSafe(_ path: VectorPath, near rect: PixelRect, margin: Double = 2) -> VectorPath {
        guard reachesFar(path, from: rect) else { return path }
        let w = window(rect, margin)
        var out = path
        out.subpaths = path.subpaths.map { s in
            let poly = clipPolygon(flatten(s, window: w).points, to: w)
            return Subpath(closed: true, knots: poly.map { Knot.corner(Double($0.x), Double($0.y)) }, op: s.op)
        }
        return out
    }

    /// The parts of `path`'s subpaths, as stroked, inside the window (`rect` grown by `margin`,
    /// which must exceed the stroke's reach so the cut ends' caps fall outside `rect`), each with
    /// the arc length it starts at along its subpath (for the dash phase). A closed subpath that
    /// stays inside is kept closed; one that leaves is walked from a point outside, so no join
    /// inside the window is cut.
    static func strokePieces(_ path: VectorPath, near rect: PixelRect, margin: Double) -> [(path: CGPath, start: Double)] {
        let w = window(rect, margin)
        var out: [(path: CGPath, start: Double)] = []
        for s in path.subpaths {
            var (pts, lens) = flatten(s, window: w)
            guard pts.count >= 2 else { continue }
            let inside = { (p: CGPoint) in w.contains(p) }
            if s.closed {
                if pts.allSatisfy(inside) {
                    let p = CGMutablePath()
                    p.addLines(between: pts)
                    p.closeSubpath()
                    out.append((p, 0))
                    continue
                }
                // Start the walk at a point outside (the closing segment is already in `pts`).
                if let k = pts.firstIndex(where: { !inside($0) }), k > 0 {
                    let total = lens.last ?? 0
                    pts = Array(pts[k...]) + Array(pts[1...k])
                    lens = Array(lens[k...]) + lens[1...k].map { $0 + total }
                }
            }
            // Liang–Barsky per segment; consecutive visible segments form one piece.
            var piece: [CGPoint] = [], start = 0.0
            func flush() {
                if piece.count >= 2 { let p = CGMutablePath(); p.addLines(between: piece); out.append((p, start)) }
                piece = []
            }
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
                var t0: CGFloat = 0, t1: CGFloat = 1
                var visible = true
                for (pk, qk) in [(-d.x, a.x - w.minX), (d.x, w.maxX - a.x), (-d.y, a.y - w.minY), (d.y, w.maxY - a.y)] {
                    if pk == 0 {
                        if qk < 0 { visible = false }
                        continue
                    }
                    let r = qk / pk
                    if pk < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
                }
                if !visible || t0 > t1 { flush(); continue }
                let p0 = CGPoint(x: a.x + t0 * d.x, y: a.y + t0 * d.y), p1 = CGPoint(x: a.x + t1 * d.x, y: a.y + t1 * d.y)
                if piece.isEmpty || t0 > 0 {
                    flush()
                    piece = [p0]
                    start = lens[i - 1] + Double(t0) * (lens[i] - lens[i - 1])
                }
                piece.append(p1)
                if t1 < 1 { flush() }
            }
            flush()
        }
        return out
    }
}

/// Hit testing for the Path Selection / Direct Selection tools (photocraft crates/vector/src/edit.rs).
public enum PathHitTest {
    public enum KnotPart: Sendable, Equatable { case anchor, inControl, outControl }

    public struct KnotHit: Sendable, Equatable {
        public var subpath: Int
        public var knot: Int
        public var part: KnotPart
        public var distance: Double
    }

    public struct SegmentHit: Sendable, Equatable {
        public var subpath: Int
        public var segment: Int
        /// Curve parameter of the nearest point.
        public var t: Double
        public var point: CGPoint
        public var distance: Double
    }

    /// Whether `p` is inside the path's fill area (operations and inversion applied).
    public static func fillContains(_ path: VectorPath, _ p: CGPoint) -> Bool {
        let inside = VectorGeometry.fillArea(path).contains(p, using: .winding)
        return path.inverted ? !inside : inside
    }

    /// Whether `p` is on the stroke.
    public static func strokeContains(_ path: VectorPath, style: StrokeStyle, _ p: CGPoint) -> Bool {
        VectorGeometry.strokeOutline(path, style: style).contains(p, using: .winding)
    }

    /// The nearest anchor or (non-retracted) handle within `tolerance`.
    public static func knot(_ path: VectorPath, near p: CGPoint, tolerance: Double) -> KnotHit? {
        var best: KnotHit?
        for (si, s) in path.subpaths.enumerated() {
            for (ki, k) in s.knots.enumerated() {
                for (part, q) in [(KnotPart.anchor, k.anchor), (.inControl, k.inCtrl), (.outControl, k.outCtrl)] {
                    if part != .anchor && q == k.anchor { continue }
                    let d = hypot(q.x - Double(p.x), q.y - Double(p.y))
                    if d <= tolerance && (best == nil || d < best!.distance || (d == best!.distance && part == .anchor)) {
                        best = KnotHit(subpath: si, knot: ki, part: part, distance: d)
                    }
                }
            }
        }
        return best
    }

    static func bezier(_ s: [PCPoint], _ t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * s[0].x + b * s[1].x + c * s[2].x + d * s[3].x, y: a * s[0].y + b * s[1].y + c * s[2].y + d * s[3].y)
    }

    /// The nearest point on any segment within `tolerance` (refined by ternary search).
    public static func segment(_ path: VectorPath, near p: CGPoint, tolerance: Double) -> SegmentHit? {
        var best: SegmentHit?
        for (si, s) in path.subpaths.enumerated() {
            for (gi, seg) in s.segments.enumerated() {
                if seg[1] == seg[0] && seg[2] == seg[3] {
                    // A straight segment: project onto the chord (t is linear, as photocraft's).
                    let dx = seg[3].x - seg[0].x, dy = seg[3].y - seg[0].y, l2 = dx * dx + dy * dy
                    let t = l2 > 0 ? min(max(((Double(p.x) - seg[0].x) * dx + (Double(p.y) - seg[0].y) * dy) / l2, 0), 1) : 0
                    let q = CGPoint(x: seg[0].x + t * dx, y: seg[0].y + t * dy)
                    let d = Double(hypot(q.x - p.x, q.y - p.y))
                    if d <= tolerance && (best == nil || d < best!.distance) { best = SegmentHit(subpath: si, segment: gi, t: t, point: q, distance: d) }
                    continue
                }
                var bt = 0.0, bd = Double.infinity
                for i in 0...64 {
                    let t = Double(i) / 64, q = bezier(seg, t)
                    let d = Double(hypot(q.x - p.x, q.y - p.y))
                    if d < bd { bd = d; bt = t }
                }
                var lo = max(bt - 1.0 / 64, 0), hi = min(bt + 1.0 / 64, 1)
                for _ in 0..<40 {
                    let m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3
                    let d1 = hypot(bezier(seg, m1).x - p.x, bezier(seg, m1).y - p.y), d2 = hypot(bezier(seg, m2).x - p.x, bezier(seg, m2).y - p.y)
                    if d1 < d2 { hi = m2 } else { lo = m1 }
                }
                let t = (lo + hi) / 2, q = bezier(seg, t), d = Double(hypot(q.x - p.x, q.y - p.y))
                if d <= tolerance && (best == nil || d < best!.distance) { best = SegmentHit(subpath: si, segment: gi, t: t, point: q, distance: d) }
            }
        }
        return best
    }
}
